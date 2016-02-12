{ CustomAdapter } = require './src/adapter'

exports.use = (robot) ->
  new CustomAdapter robot
