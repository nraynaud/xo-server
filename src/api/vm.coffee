$assign = require 'lodash/assign'
$debug = (require 'debug') 'xo:api:vm'
$filter = require 'lodash/filter'
$findIndex = require 'lodash/findIndex'
$findWhere = require 'lodash/find'
endsWith = require 'lodash/endsWith'
escapeStringRegexp = require 'escape-string-regexp'
eventToPromise = require 'event-to-promise'
sortBy = require 'lodash/sortBy'
startsWith = require 'lodash/startsWith'
{coroutine: $coroutine} = require 'bluebird'
{format} = require 'json-rpc-peer'

{
  GenericError,
  InvalidParameters,
  Unauthorized
} = require('../api-errors')
{
  forEach,
  formatXml: $js2xml,
  isArray: $isArray,
  map,
  mapToArray,
  noop,
  parseSize,
  parseXml,
  pCatch,
  pFinally
} = require '../utils'
{isVmRunning: $isVmRunning} = require('../xapi')

#=====================================================================

checkPermissionOnSrs = (vm, permission = 'operate') -> (
  permissions = []
  forEach(vm.$VBDs, (vbdId) =>
    vbd = @getObject(vbdId, 'VBD')
    vdiId = vbd.VDI

    if vbd.is_cd_drive or not vdiId
      return

    permissions.push([
      @getObject(vdiId, 'VDI').$SR,
      permission
    ])
  )

  return @hasPermissions(@session.get('user_id'), permissions).then((success) => (
    throw new Unauthorized() unless success
  ))
)

#=====================================================================

extract = (obj, prop) ->
  value = obj[prop]
  delete obj[prop]
  return value

# TODO: Implement ACLs
create = $coroutine (params) ->
  template = extract(params, 'template')
  params.template = template._xapiId

  xapi = this.getXapi(template)

  objectIds = [
    template.id
  ]
  limits = {
    cpus: template.CPUs.number,
    disk: 0,
    memory: template.memory.dynamic[1],
    vms: 1
  }
  vdiSizesByDevice = {}
  forEach(xapi.getObject(template._xapiId).$VBDs, (vbd) =>
    if (
      vbd.type is 'Disk' and
      (vdi = vbd.$VDI)
    )
      vdiSizesByDevice[vbd.device] = +vdi.virtual_size

    return
  )

  vdis = extract(params, 'VDIs')
  params.vdis = vdis and map(vdis, (vdi) =>
    sr = @getObject(vdi.SR)
    size = parseSize(vdi.size)

    objectIds.push(sr.id)
    limits.disk += size

    return $assign({}, vdi, {
      device: vdi.device ? vdi.position,
      size,
      SR: sr._xapiId,
      type: vdi.type
    })
  )

  existingVdis = extract(params, 'existingDisks')
  params.existingVdis = existingVdis and map(existingVdis, (vdi, device) =>
    if vdi.size?
      size = parseSize(vdi.size)
      vdiSizesByDevice[device] = size

    if vdi.$SR
      sr = @getObject(vdi.$SR)
      objectIds.push(sr.id)

    return $assign({}, vdi, {
      size,
      $SR: sr and sr._xapiId
    })
  )

  forEach(vdiSizesByDevice, (size) => limits.disk += size)

  vifs = extract(params, 'VIFs')
  params.vifs = vifs and map(vifs, (vif) =>
    network = @getObject(vif.network)

    objectIds.push(network.id)

    return {
      mac: vif.mac
      network: network._xapiId
    }
  )

  installation = extract(params, 'installation')
  params.installRepository = installation && installation.repository

  resourceSet = extract(params, 'resourceSet')

  xapiVm = yield xapi.createVm(template._xapiId, params)
  vm = xapi.xo.addObject(xapiVm)

  { user } = this
  if resourceSet
    yield this.checkResourceSetConstraints(resourceSet, user.id, objectIds)
    yield this.allocateLimitsInResourceSet(limits, resourceSet)
  else unless user.permission is 'admin'
    throw new Unauthorized()

  if resourceSet
    yield Promise.all([
      @addAcl(user.id, vm.id, 'admin')
      xapi.xo.setData(xapiVm.$id, 'resourceSet', resourceSet)
    ])

  return vm.id

create.params = {
  cloudConfig: {
    type: 'string'
    optional: true
  }

  coreOs: {
    type: 'boolean'
    optional: true
  }

  clone: {
    type: 'boolean'
    optional: true
  }

  resourceSet: {
    type: 'string',
    optional: true
  },

  installation: {
    type: 'object'
    optional: true
    properties: {
      method: { type: 'string' }
      repository: { type: 'string' }
    }
  }

  # Name/description of the new VM.
  name_label: { type: 'string' }
  name_description: { type: 'string', optional: true }

  # PV Args
  pv_args: { type: 'string', optional: true }

  # TODO: add the install repository!
  # VBD.insert/eject
  # Also for the console!

  # UUID of the template the VM will be created from.
  template: { type: 'string' }

  # Virtual interfaces to create for the new VM.
  VIFs: {
    type: 'array'
    items: {
      type: 'object'
      properties: {
        # UUID of the network to create the interface in.
        network: { type: 'string' }

        mac: {
          optional: true # Auto-generated per default.
          type: 'string'
        }
      }
    }
  }

  # Virtual disks to create for the new VM.
  VDIs: {
    optional: true # If not defined, use the template parameters.
    type: 'array'
    items: {
      type: 'object'
      properties: {
        device: { type: 'string' }
        size: { type: ['integer', 'string'] }
        SR: { type: 'string' }
        type: { type: 'string' }
      }
    }
  }

  # TODO: rename to *existingVdis* or rename *VDIs* to *disks*.
  existingDisks: {
    optional: true,
    type: 'object',

    # Do not for a type object.
    items: {
      type: 'object',
      properties: {
        size: {
          type: ['integer', 'string'],
          optional: true
        },
        $SR: {
          type: 'string',
          optional: true
        }
      }
    }
  }
}

create.resolve = {
  template: ['template', 'VM-template', 'administrate'],
}

exports.create = create

#---------------------------------------------------------------------

delete_ = ({vm, delete_disks: deleteDisks}) ->
  cpus = vm.CPUs.number
  memory = vm.memory.size

  xapi = @getXapi(vm)

  resourceSet = xapi.xo.getData(vm._xapiId, 'resourceSet')
  if resourceSet?
    disk = 0
    vdis = {}
    forEach(vm.$VBDs, (vbd) =>
      if (
        vbd.type is 'Disk' and
        (vdi = vbd.$VDI) and
        not vdis[vdi.$id]
      )
        vdis[vdi.$id] = true
        disk += +vdi.virtual_size

      return
    )

    pCatch.call(@releaseLimitsInResourceSet(
      @computeVmResourcesUsage(vm),
      resourceSet
    ), noop)

  return xapi.deleteVm(vm._xapiId, deleteDisks)

delete_.params = {
  id: { type: 'string' }

  delete_disks: {
    optional: true
    type: 'boolean'
  }
}
delete_.resolve = {
  vm: ['id', ['VM', 'VM-snapshot', 'VM-template'], 'administrate']
}

exports.delete = delete_

#---------------------------------------------------------------------

ejectCd = $coroutine ({vm}) ->
  yield @getXapi(vm).ejectCdFromVm(vm._xapiId)
  return

ejectCd.params = {
  id: { type: 'string' }
}

ejectCd.resolve = {
  vm: ['id', 'VM', 'operate']
}
exports.ejectCd = ejectCd

#---------------------------------------------------------------------

insertCd = $coroutine ({vm, vdi, force}) ->
  yield @getXapi(vm).insertCdIntoVm(vdi._xapiId, vm._xapiId, {force})
  return

insertCd.params = {
  id: { type: 'string' }
  cd_id: { type: 'string' }
  force: { type: 'boolean' }
}

insertCd.resolve = {
  vm: ['id', 'VM', 'operate'],
  vdi: ['cd_id', 'VDI', 'view'],
}
exports.insertCd = insertCd

#---------------------------------------------------------------------

migrate = $coroutine ({
  vm,
  host,
  mapVdisSrs,
  mapVifsNetworks,
  migrationNetwork
}) ->
  permissions = []

  if mapVdisSrs
    mapVdisSrsXapi = {}
    forEach mapVdisSrs, (srId, vdiId) =>
      vdiXapiId = @getObject(vdiId, 'VDI')._xapiId
      mapVdisSrsXapi[vdiXapiId] = @getObject(srId, 'SR')._xapiId
      permissions.push([
        srId,
        'administrate'
      ])

  if mapVifsNetworks
    mapVifsNetworksXapi = {}
    forEach mapVifsNetworks, (networkId, vifId) =>
      vifXapiId = @getObject(vifId, 'VIF')._xapiId
      mapVifsNetworksXapi[vifXapiId] = @getObject(networkId, 'network')._xapiId
      permissions.push([
        networkId,
        'administrate'
      ])

  unless yield @hasPermissions(@session.get('user_id'), permissions)
    throw new Unauthorized()

  yield @getXapi(vm).migrateVm(vm._xapiId, @getXapi(host), host._xapiId, {
    migrationNetworkId: migrationNetwork?._xapiId
    mapVifsNetworks: mapVifsNetworksXapi,
    mapVdisSrs: mapVdisSrsXapi,
  })
  return

migrate.params = {

  # Identifier of the VM to migrate.
  vm: { type: 'string' }

  # Identifier of the host to migrate to.
  targetHost: { type: 'string' }

  # Map VDIs IDs --> SRs IDs
  mapVdisSrs: { type: 'object', optional: true }

  # Map VIFs IDs --> Networks IDs
  mapVifsNetworks: { type: 'object', optional: true }

  # Identifier of the Network use for the migration
  migrationNetwork: { type: 'string', optional: true }
}

migrate.resolve = {
  vm: ['vm', 'VM', 'administrate'],
  host: ['targetHost', 'host', 'administrate'],
  migrationNetwork: ['migrationNetwork', 'network', 'administrate'],
}

exports.migrate = migrate

#---------------------------------------------------------------------

set = (params) ->
  VM = extract(params, 'VM')
  xapi = @getXapi(VM)

  return xapi.editVm(VM._xapiId, params, (limits, vm) =>
    resourceSet = xapi.xo.getData(vm, 'resourceSet')

    if (resourceSet)
      return @allocateLimitsInResourceSet(limits, resourceSet)

    if (limits.cpuWeight && this.user.permission != 'admin')
      throw new Unauthorized()
  )

set.params = {
  # Identifier of the VM to update.
  id: { type: 'string' }

  name_label: { type: 'string', optional: true }

  name_description: { type: 'string', optional: true }

  # TODO: provides better filtering of values for HA possible values: "best-
  # effort" meaning "try to restart this VM if possible but don't consider the
  # Pool to be overcommitted if this is not possible"; "restart" meaning "this
  # VM should be restarted"; "" meaning "do not try to restart this VM"
  high_availability: { type: 'boolean', optional: true }

  # Number of virtual CPUs to allocate.
  CPUs: { type: 'integer', optional: true }

  cpusMax: { type: ['integer', 'string'], optional: true }

  # Memory to allocate (in bytes).
  #
  # Note: static_min ≤ dynamic_min ≤ dynamic_max ≤ static_max
  memory: { type: ['integer', 'string'], optional: true }

  # Set dynamic_min
  memoryMin: { type: ['integer', 'string'], optional: true }

  # Set dynamic_max
  memoryMax: { type: ['integer', 'string'], optional: true }

  # Set static_max
  memoryStaticMax: { type: ['integer', 'string'], optional: true }

  # Kernel arguments for PV VM.
  PV_args: { type: 'string', optional: true }

  cpuWeight: { type: ['integer', 'null'], optional: true }

  cpuCap: { type: ['integer', 'null'], optional: true }
}

set.resolve = {
  VM: ['id', ['VM', 'VM-snapshot'], 'administrate']
}

exports.set = set

#---------------------------------------------------------------------

restart = $coroutine ({vm, force}) ->
  xapi = @getXapi(vm)

  if force
    yield xapi.call 'VM.hard_reboot', vm._xapiRef
  else
    yield xapi.call 'VM.clean_reboot', vm._xapiRef

  return true

restart.params = {
  id: { type: 'string' }
  force: { type: 'boolean' }
}

restart.resolve = {
  vm: ['id', 'VM', 'operate']
}

exports.restart = restart

#---------------------------------------------------------------------

# TODO: implement resource sets
clone = $coroutine ({vm, name, full_copy}) ->
  yield checkPermissionOnSrs.call(this, vm)

  return @getXapi(vm).cloneVm(vm._xapiRef, {
    nameLabel: name,
    fast: not full_copy
  }).then((vm) -> vm.$id)

clone.params = {
  id: { type: 'string' }
  name: { type: 'string' }
  full_copy: { type: 'boolean' }
}

clone.resolve = {
  # TODO: is it necessary for snapshots?
  vm: ['id', 'VM', 'administrate']
}

exports.clone = clone

#---------------------------------------------------------------------

# TODO: implement resource sets
copy = $coroutine ({
  compress,
  name: nameLabel,
  sr,
  vm
}) ->
  if vm.$pool == sr.$pool
    if vm.power_state is 'Running'
      yield checkPermissionOnSrs.call(this, vm)

    return @getXapi(vm).copyVm(vm._xapiId, sr._xapiId, {
      nameLabel
    }).then((vm) -> vm.$id)

  return @getXapi(vm).remoteCopyVm(vm._xapiId, @getXapi(sr), sr._xapiId, {
    compress,
    nameLabel
  }).then((vm) -> vm.$id)

copy.params = {
  compress: {
    type: 'boolean',
    optional: true
  },
  name: {
    type: 'string',
    optional: true
  },
  vm: { type: 'string' },
  sr: { type: 'string' }
}

copy.resolve = {
  vm: [ 'vm', 'VM', 'administrate' ]
  sr: [ 'sr', 'SR', 'operate' ]
}

exports.copy = copy

#---------------------------------------------------------------------

convertToTemplate = $coroutine ({vm}) ->
  # Convert to a template requires pool admin permission.
  unless yield @hasPermissions(@session.get('user_id'), [
    [ vm.$pool, 'administrate' ]
  ])
    throw new Unauthorized()

  yield @getXapi(vm).call 'VM.set_is_a_template', vm._xapiRef, true

  return true

convertToTemplate.params = {
  id: { type: 'string' }
}

convertToTemplate.resolve = {
  vm: ['id', ['VM', 'VM-snapshot'], 'administrate']
}
exports.convertToTemplate = convertToTemplate

# TODO: remove when no longer used.
exports.convert = convertToTemplate

#---------------------------------------------------------------------

# TODO: implement resource sets
snapshot = $coroutine ({vm, name}) ->
  yield checkPermissionOnSrs.call(this, vm)

  snapshot = yield @getXapi(vm).snapshotVm(vm._xapiRef, name ? "#{vm.name_label}_#{new Date().toISOString()}")
  return snapshot.$id

snapshot.params = {
  id: { type: 'string' }
  name: { type: 'string', optional: true }
}

snapshot.resolve = {
  vm: ['id', 'VM', 'administrate']
}
exports.snapshot = snapshot

#---------------------------------------------------------------------

rollingDeltaBackup = $coroutine ({vm, remote, tag, depth}) ->
  return yield @rollingDeltaVmBackup({
    vm,
    remoteId: remote,
    tag,
    depth
  })

rollingDeltaBackup.params = {
  id: { type: 'string' }
  remote: { type: 'string' }
  tag: { type: 'string'}
  depth: { type: ['string', 'number'] }
}

rollingDeltaBackup.resolve = {
  vm: ['id', ['VM', 'VM-snapshot'], 'administrate']
}

rollingDeltaBackup.permission = 'admin'

exports.rollingDeltaBackup = rollingDeltaBackup

#---------------------------------------------------------------------

importDeltaBackup = ({sr, remote, filePath}) ->
  return @importDeltaVmBackup({sr, remoteId: remote, filePath})

importDeltaBackup.params = {
  sr: { type: 'string' }
  remote: { type: 'string' }
  filePath: { type: 'string' }
}

importDeltaBackup.resolve = {
  sr: [ 'sr', 'SR', 'operate' ]
}

importDeltaBackup.permission = 'admin'

exports.importDeltaBackup = importDeltaBackup

#---------------------------------------------------------------------

deltaCopy = ({ vm, sr }) -> @deltaCopyVm(vm, sr)

deltaCopy.params = {
  id: { type: 'string' },
  sr: { type: 'string' }
}

deltaCopy.resolve = {
  vm: [ 'id', 'VM', 'operate'],
  sr: [ 'sr', 'SR', 'operate']
}

exports.deltaCopy = deltaCopy

#---------------------------------------------------------------------

rollingSnapshot = $coroutine ({vm, tag, depth}) ->
  yield checkPermissionOnSrs.call(this, vm)
  yield @rollingSnapshotVm(vm, tag, depth)

rollingSnapshot.params = {
  id: { type: 'string' }
  tag: { type: 'string' }
  depth: { type: 'number' }
}

rollingSnapshot.resolve = {
  vm: ['id', 'VM', 'administrate']
}

rollingSnapshot.description = 'Snapshots a VM with a tagged name, and removes the oldest snapshot with the same tag according to depth'

exports.rollingSnapshot = rollingSnapshot

#---------------------------------------------------------------------

backup = $coroutine ({vm, remoteId, file, compress, onlyMetadata}) ->
  yield @backupVm({vm, remoteId, file, compress, onlyMetadata})

backup.permission = 'admin'

backup.params = {
  id: {type: 'string'}
  remoteId: { type: 'string' }
  file: { type: 'string' }
  compress: { type: 'boolean', optional: true }
  onlyMetadata: { type: 'boolean', optional: true }
}

backup.resolve = {
  vm: ['id', 'VM', 'administrate']
}

backup.description = 'Exports a VM to the file system'

exports.backup = backup

#---------------------------------------------------------------------

importBackup = ({remote, file, sr}) -> @importVmBackup(remote, file, sr)

importBackup.permission = 'admin'
importBackup.description = 'Imports a VM into host, from a file found in the chosen remote'
importBackup.params = {
  remote: {type: 'string'},
  file: {type: 'string'},
  sr: {type: 'string'}
}

importBackup.resolve = {
  sr: [ 'sr', 'SR', 'operate' ]
}

importBackup.permission = 'admin'

exports.importBackup = importBackup

#---------------------------------------------------------------------

rollingBackup = $coroutine ({vm, remoteId, tag, depth, compress, onlyMetadata}) ->
  return yield @rollingBackupVm({
    vm,
    remoteId,
    tag,
    depth,
    compress,
    onlyMetadata
  })

rollingBackup.permission = 'admin'

rollingBackup.params = {
  id: { type: 'string' }
  remoteId: { type: 'string' }
  tag: { type: 'string'}
  depth: { type: 'number' }
  compress: { type: 'boolean', optional: true }
}

rollingBackup.resolve = {
  vm: ['id', ['VM', 'VM-snapshot'], 'administrate']
}

rollingBackup.description = 'Exports a VM to the file system with a tagged name, and removes the oldest backup with the same tag according to depth'

exports.rollingBackup = rollingBackup

#---------------------------------------------------------------------

rollingDrCopy = ({vm, pool, sr, tag, depth}) ->
  unless sr
    unless pool
      throw new InvalidParameters('either pool or sr param should be specified')

    if vm.$pool is pool.id
      throw new GenericError('Disaster Recovery attempts to copy on the same pool')

    sr = @getObject(pool.default_SR, 'SR')

  return @rollingDrCopyVm({vm, sr, tag, depth})

rollingDrCopy.params = {
  depth: { type: 'number' }
  id: { type: 'string' }
  pool: { type: 'string', optional: true }
  sr: { type: 'string', optional: true }
  tag: { type: 'string'}
}

rollingDrCopy.resolve = {
  vm: ['id', ['VM', 'VM-snapshot'], 'administrate'],
  pool: ['pool', 'pool', 'administrate']
  sr: ['sr', 'SR', 'administrate']
}

rollingDrCopy.description = 'Copies a VM to a different pool, with a tagged name, and removes the oldest VM with the same tag from this pool, according to depth'

exports.rollingDrCopy = rollingDrCopy

#---------------------------------------------------------------------

start = ({vm}) ->
  return @getXapi(vm).startVm(vm._xapiId)

start.params = {
  id: { type: 'string' }
}

start.resolve = {
  vm: ['id', 'VM', 'operate']
}

exports.start = start

#---------------------------------------------------------------------

# TODO: implements timeout.
# - if !force → clean shutdown
# - if force is true → hard shutdown
# - if force is integer → clean shutdown and after force seconds, hard shutdown.
stop = $coroutine ({vm, force}) ->
  xapi = @getXapi vm

  # Hard shutdown
  if force
    yield xapi.call 'VM.hard_shutdown', vm._xapiRef
    return true

  # Clean shutdown
  try
    yield xapi.call 'VM.clean_shutdown', vm._xapiRef
  catch error
    if error.code is 'VM_MISSING_PV_DRIVERS' or error.code is 'VM_LACKS_FEATURE_SHUTDOWN'
      throw new InvalidParameters('clean shutdown requires PV drivers')
    else
      throw error

  return true

stop.params = {
  id: { type: 'string' }
  force: { type: 'boolean', optional: true }
}

stop.resolve = {
  vm: ['id', 'VM', 'operate']
}

exports.stop = stop

#---------------------------------------------------------------------

suspend = $coroutine ({vm}) ->
  yield @getXapi(vm).call 'VM.suspend', vm._xapiRef

  return true

suspend.params = {
  id: { type: 'string' }
}

suspend.resolve = {
  vm: ['id', 'VM', 'operate']
}
exports.suspend = suspend

#---------------------------------------------------------------------

resume = $coroutine ({vm, force}) ->
  # FIXME: WTF this is?
  if not force
    force = true

  yield @getXapi(vm).call 'VM.resume', vm._xapiRef, false, force

  return true

resume.params = {
  id: { type: 'string' }
  force: { type: 'boolean', optional: true }
}

resume.resolve = {
  vm: ['id', 'VM', 'operate']
}
exports.resume = resume

#---------------------------------------------------------------------

# revert a snapshot to its parent VM
revert = $coroutine ({snapshot}) ->
  # Attempts a revert from this snapshot to its parent VM
  yield @getXapi(snapshot).call 'VM.revert', snapshot._xapiRef

  return true

revert.params = {
  id: { type: 'string' }
}

revert.resolve = {
  snapshot: ['id', 'VM-snapshot', 'administrate']
}
exports.revert = revert

#---------------------------------------------------------------------

handleExport = $coroutine (req, res, {xapi, id, compress, onlyMetadata}) ->
  stream = yield xapi.exportVm(id, {
    compress: compress ? true,
    onlyMetadata: onlyMetadata ? false
  })
  res.on('close', () ->
    stream.cancel()
  )
  # Remove the filename as it is already part of the URL.
  stream.headers['content-disposition'] = 'attachment'

  res.writeHead(
    stream.statusCode,
    stream.statusMessage ? '',
    stream.headers
  )
  stream.pipe(res)
  return

# TODO: integrate in xapi.js
export_ = $coroutine ({vm, compress, onlyMetadata}) ->
  if vm.power_state is 'Running'
    yield checkPermissionOnSrs.call(this, vm)

  data = {
    xapi: @getXapi(vm),
    id: vm._xapiId,
    compress,
    onlyMetadata
  }

  return {
    $getFrom: yield @registerHttpRequest(handleExport, data, {
      suffix: encodeURI("/#{vm.name_label}.xva")
    })
  }

export_.params = {
  vm: { type: 'string' }
  compress: { type: 'boolean', optional: true }
  onlyMetadata: { type: 'boolean', optional: true }
}

export_.resolve = {
  vm: ['vm', ['VM', 'VM-snapshot'], 'administrate'],
}
exports.export = export_;

#---------------------------------------------------------------------

handleVmImport = $coroutine (req, res, { data, srId, type }) ->
  # Timeout seems to be broken in Node 4.
  # See https://github.com/nodejs/node/issues/3319
  req.setTimeout(43200000) # 12 hours

  try
    vm = yield xapi.importVm(req, { data, srId, type, xapi })
    res.end(format.response(0, vm.$id))
  catch e
    res.writeHead(500)
    res.end(format.error(0, new GenericError(e.message)))

  return

# TODO: "sr_id" can be passed in URL to target a specific SR
import_ = $coroutine ({ data, host, sr, type }) ->
  if not sr
    if not host
      throw new InvalidParameters('you must provide either host or SR')

    xapi = @getXapi(host)
    sr = xapi.pool.$default_SR
    if not sr
      throw new InvalidParameters('there is not default SR in this pool')

    # FIXME: must have administrate permission on default SR.
  else
    xapi = @getXapi(sr)

  return {
    $sendTo: yield @registerHttpRequest(handleVmImport, {
      data,
      srId: sr._xapiId,
      type,
      xapi
    })
  }

import_.params = {
  data: {
    type: 'object',
    optional: true,
    properties: {
      descriptionLabel: { type: 'string' },
      disks: {
        type: 'array',
        items: {
          type: 'object',
          properties: {
            capacity: { type: 'integer' },
            descriptionLabel: { type: 'string' },
            nameLabel: { type: 'string' },
            path: { type: 'string' },
            position: { type: 'integer' }
          }
        },
        optional: true
      },
      memory: { type: 'integer' },
      nameLabel: { type: 'string' },
      nCpus: { type: 'integer' },
      networks: {
        type: 'array',
        items: { type: 'string' },
        optional: true
      },
    }
  },
  host: { type: 'string', optional: true },
  type: { type: 'string', optional: true },
  sr: { type: 'string', optional: true }
}

import_.resolve = {
  host: ['host', 'host', 'administrate'],
  sr: ['sr', 'SR', 'administrate']
}
exports.import = import_

#---------------------------------------------------------------------

# FIXME: if position is used, all other disks after this position
# should be shifted.
attachDisk = $coroutine ({vm, vdi, position, mode, bootable}) ->
  yield @getXapi(vm).attachVdiToVm(vdi._xapiId, vm._xapiId, {
    bootable,
    position,
    readOnly: mode is 'RO'
  })
  return

attachDisk.params = {
  bootable: {
    type: 'boolean'
    optional: true
  }
  mode: { type: 'string', optional: true }
  position: { type: 'string', optional: true }
  vdi: { type: 'string' }
  vm: { type: 'string' }
}

attachDisk.resolve = {
  vm: ['vm', 'VM', 'administrate'],
  vdi: ['vdi', 'VDI', 'administrate'],
}
exports.attachDisk = attachDisk

#---------------------------------------------------------------------

# TODO: implement resource sets
createInterface = $coroutine ({vm, network, position, mtu, mac}) ->
  vif = yield @getXapi(vm).createVif(vm._xapiId, network._xapiId, {
    mac,
    mtu,
    position
  })

  return vif.$id

createInterface.params = {
  vm: { type: 'string' }
  network: { type: 'string' }
  position: { type: 'string', optional: true }
  mtu: { type: 'string', optional: true }
  mac: { type: 'string', optional: true }
}

createInterface.resolve = {
  vm: ['vm', 'VM', 'administrate'],
  network: ['network', 'network', 'view'],
}
exports.createInterface = createInterface

#---------------------------------------------------------------------

attachPci = $coroutine ({vm, pciId}) ->
  xapi = @getXapi vm

  yield xapi.call 'VM.add_to_other_config', vm._xapiRef, 'pci', pciId

  return true


attachPci.params = {
  vm: { type: 'string' }
  pciId: { type: 'string' }
}

attachPci.resolve = {
  vm: ['vm', 'VM', 'administrate'],
}
exports.attachPci = attachPci

#---------------------------------------------------------------------

detachPci = $coroutine ({vm}) ->
  xapi = @getXapi vm

  yield xapi.call 'VM.remove_from_other_config', vm._xapiRef, 'pci'

  return true


detachPci.params = {
  vm: { type: 'string' }
}

detachPci.resolve = {
  vm: ['vm', 'VM', 'administrate'],
}
exports.detachPci = detachPci
#---------------------------------------------------------------------

stats = $coroutine ({vm, granularity}) ->
  stats = yield @getXapiVmStats(vm, granularity)
  return stats

stats.description = 'returns statistics about the VM'

stats.params = {
  id: { type: 'string' },
  granularity: {
    type: 'string',
    optional: true
  }
}

stats.resolve = {
  vm: ['id', ['VM', 'VM-snapshot'], 'view'],
}

exports.stats = stats;

#---------------------------------------------------------------------

setBootOrder = $coroutine ({vm, order}) ->
  xapi = @getXapi vm

  order = {order: order}
  if vm.virtualizationMode == 'hvm'
    yield xapi.call 'VM.set_HVM_boot_params', vm._xapiRef, order
    return true

  throw new InvalidParameters('You can only set the boot order on a HVM guest')

setBootOrder.params = {
  vm: { type: 'string' },
  order: { type: 'string' }
}

setBootOrder.resolve = {
  vm: ['vm', 'VM', 'operate'],
}
exports.setBootOrder = setBootOrder

#---------------------------------------------------------------------

recoveryStart = ({vm}) ->
  return @getXapi(vm).startVmOnCd(vm._xapiId)

recoveryStart.params = {
  id: { type: 'string' }
}

recoveryStart.resolve = {
  vm: ['id', 'VM', 'operate'],
}
exports.recoveryStart = recoveryStart

#---------------------------------------------------------------------

getCloudInitConfig = $coroutine ({template}) ->
  return yield @getXapi(template).getCloudInitConfig(template._xapiId)

getCloudInitConfig.params = {
  template: { type: 'string' }
}

getCloudInitConfig.resolve = {
  template: ['template', 'VM-template', 'administrate'],
}
exports.getCloudInitConfig = getCloudInitConfig

#---------------------------------------------------------------------

createCloudInitConfigDrive = $coroutine ({vm, sr, config, coreos}) ->
  xapi = @getXapi vm
  # CoreOS is a special CloudConfig drive created by XS plugin
  if coreos
    yield xapi.createCoreOsCloudInitConfigDrive(vm._xapiId, sr._xapiId, config)
  # use generic Cloud Init drive
  else
    yield xapi.createCloudInitConfigDrive(vm._xapiId, sr._xapiId, config)
  return true

createCloudInitConfigDrive.params = {
  vm: { type: 'string' },
  sr: { type: 'string' },
  config: { type: 'string' }
}

createCloudInitConfigDrive.resolve = {
  vm: ['vm', 'VM', 'administrate'],

  # Not compatible with resource sets.
  # FIXME: find a workaround.
  sr: [ 'sr', 'SR', '' ] # 'operate' ]
}
exports.createCloudInitConfigDrive = createCloudInitConfigDrive

#=====================================================================

Object.defineProperty(exports, '__esModule', {
  value: true
})
