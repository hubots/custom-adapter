HTTP = require 'http'
HTTPS = require 'https'
{ EventEmitter } = require 'events'

class Client extends EventEmitter
  constructor: (options, @robot) ->
    @host = options.host
    @port = options.port

    unless options.token?
      @robot.logger.error \
        "Not enough parameters provided. I need a token"
      process.exit(1)

    @token         = options.token
    @authorization = "Basic " + new Buffer("#{@token}").toString("base64")
    @http          = if @port == 443 then HTTPS else HTTP

  getUser: (id, callback) ->
    @get "/api/user/#{id}", callback

  me: (callback) ->
    @get "/api/me", callback

  sendMessage: (thread_id, text, callback) ->
    body = { body: text }
    @post "/api/thread/#{thread_id}", body, callback

  # listen for activity in channels
  listen: ->
    host = @host
    headers =
      "Host"          : host
      "Authorization" : self.authorization
      "User-Agent"    : "Hubot/#{@robot?.version} (#{@robot?.name})"

    options =
      "agent"  : false
      "host"   : host
      "port"   : @port
      "path"   : "/api/event/stream"
      "method" : "GET"
      "headers": headers

    logger.debug "request: %s", json(options)

    request = self.http.request options, (response) ->
      response.setEncoding("utf8")
      contentType = response.headers['content-type']
      sse = contentType == "text/event-stream"

      buf = ''

      # TODO ignore non-message events
      response.on "data", (chunk) ->
        if chunk is ' '
          # campfire api sends a ' ' heartbeat every 3s
          logger.debug "heartbeat"
          return

        logger.debug "data: %s", chunk

        if chunk.match(/^\s*Access Denied/)
          logger.error "error: #{chunk}"

        else
          # api uses newline terminated json payloads
          # buffer across tcp packets and parse out lines
          buf += chunk

          while (i = buf.indexOf("\r")) > -1 or (i = buf.indexOf("\n")) > -1
            part = buf.substr(0, i).trim()
            buf = buf.substr(i + 1)

            # support text/event-stream
            if sse
              i = part.indexOf(":")
              if i >= 0
                part = part.substr(i + 1).trim()
            continue unless part

            if part
              try
                data = JSON.parse part
                logger.debug "json data: %s", json(data)
                thread_id = data.thread_id || data.body?.thread_id
                body = if data.body then data.body.body || data.body else {}
                type = data.type || data.name
                if type == "message"
                  type = "TextMessage"
                self.emit(
                  type,
                  data.id,
                  data.created_at,
                  thread_id,
                  data.user_id || data.actor,
                  body
                )
              catch error
                logger.error "data error: #{error}\n#{error.stack}"

      response.on "end", ->
        logger.error "streaming connection closed"
        setTimeout ->
          self.emit "reconnect"
        , 5000

      response.on "error", (err) ->
        logger.error "Campfire listen response error: #{err}"

    request.on "error", (err) ->
      logger.error "Campfire listen request error: #{err}"

    request.end()

  get: (path, callback) ->
    @request "GET", path, null, callback

  post: (path, body, callback) ->
    @request "POST", path, body, callback

  put: (path, body, callback) ->
    @request "PUT", path, body, callback

  request: (method, path, body, callback) ->
    logger = @robot.logger

    headers =
      "Authorization" : @authorization
      "Host"          : @host
      "Content-Type"  : "application/json"
      "User-Agent"    : "Hubot/#{@robot?.version} (#{@robot?.name})"

    options =
      "agent"  : false
      "host"   : @host
      "port"   : @port || 443
      "path"   : path
      "method" : method
      "headers": headers

    if method is "POST" || method is "PUT"
      if typeof(body) isnt "string"
        body = JSON.stringify body

      body = new Buffer(body)
      options.headers["Content-Length"] = body.length

    logger.debug "request: %s", json(options)

    request = @http.request options, (response) ->
      data = ""

      response.on "data", (chunk) ->
        logger.debug "data chunk: %s", chunk
        data += chunk

      response.on "end", ->
        if response.statusCode >= 400
          switch response.statusCode
            when 401
              throw new Error "Invalid access token provided"
            else
              logger.error "server status code: #{response.statusCode}"
              logger.error "server response data: #{data}"

        if callback
          try
            callback null, JSON.parse(data)
          catch error
            callback null, data or { }

      response.on "error", (err) ->
        logger.error "Campfire response error: #{err}"
        callback err, { }

    if method is "POST" || method is "PUT"
      request.end(body, 'binary')
    else
      request.end()

    request.on "error", (err) ->
      logger.error "Campfire request error: #{err}"

pretty_json = true
json = (d) ->
  if pretty_json then JSON.stringify(d, null, 2) else JSON.stringify(d)

exports.Client = Client
exports.json = json
