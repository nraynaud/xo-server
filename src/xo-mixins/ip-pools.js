import { NoSuchObject } from '../api-errors'
import {
  generateUnsecureToken,
  streamToArray,
  throwFn
} from '../utils'

// ===================================================================

class NoSuchIpPool extends NoSuchObject {
  constructor (id) {
    super(id, 'ip pool')
  }
}

const normalize = ({
  id = throwFn('id is a required field'),
  name = ''
}) => ({
  id,
  name
})

// ===================================================================

export default class IpPools {
  constructor (xo) {
    this._store = null
    this._xo = xo

    xo.on('start', async () => {
      this._store = await xo.getStore('ipPools')
    })
  }

  async createIpPool ({ name }) {
    const id = await this._generateId()

    await this._save({
      id,
      name
    })

    return id
  }

  async deleteIpPool (id) {
    const store = this._store

    if (await store.has(id)) {
      return store.del(id)
    }

    throw new NoSuchIpPool(id)
  }

  getAllIpPools () {
    return streamToArray(this._store.createValueStream(), {
      mapper: normalize
    })
  }

  getIpPool (id) {
    return this._store.get(id).then(normalize, error => {
      throw error.notFound ? new NoSuchIpPool(id) : error
    })
  }

  async updateIpPool (id, {
    name
  }) {
    const ipPool = await this.getIpPool(id)

    name != null && (ipPool.name = name)

    await this._save(ipPool)
  }

  async _generateId () {
    let id
    do {
      id = generateUnsecureToken(8)
    } while (await this._store.has(id))
    return id
  }

  _save (ipPool) {
    ipPool = normalize(ipPool)
    return this._store.put(ipPool.id, ipPool)
  }
}
