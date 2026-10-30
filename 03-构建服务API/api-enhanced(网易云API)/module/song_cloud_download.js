// 从云盘获取歌曲下载链接

const createOption = require('../util/option.js')
module.exports = (query, request) => {
  const data = {
    songId: query.id,
  }
  return request(`/api/cloud/dowonload`, data, createOption(query, 'eapi'))
}
