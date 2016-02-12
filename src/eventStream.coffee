HTTP = require 'http'
HTTPS = require 'https'
{ EventEmitter } = require 'events'

class EventStream extends EventEmitter
  constructor: (options, @robot) ->
    @port = options.port
    @host = options.host
    @prefix = options.prefix
    @custom = options.host? or options.prefix?

    unless options.token? and options.account?
      @robot.logger.error \
        "Not enough parameters provided. I need a token and account"
      process.exit(1)

    @token         = options.token
    @rooms         = (options.rooms || "").split(",").filter(identity)
    @account       = options.account
    @host          = @host || @account + ".campfirenow.com"
    @authorization = "Basic " + new Buffer("#{@token}").toString("base64")
    @private       = {}
    @http          = if @port == 443 then HTTPS else HTTP

  Rooms: (callback) ->
    @get "/rooms", callback

  User: (id, callback) ->
    @get "/users/#{id}", callback

  Me: (callback) ->
    @get "/users/me", callback

  Room: (id) ->
    self = @
    logger = @robot.logger

    unless id
      logger.error "empty room id"
      return null

    show: (callback) ->
      self.get "/room/#{id}", callback

    join: (callback) ->
      self.post "/room/#{id}/join", "", callback

    leave: (callback) ->
      self.post "/room/#{id}/leave", "", callback

    lock: (callback) ->
      self.post "/room/#{id}/lock", "", callback

    unlock: (callback) ->
      self.post "/room/#{id}/unlock", "", callback

    # say things to this channel on behalf of the token user
    paste: (text, callback) ->
      @message text, "PasteMessage", callback

    topic: (text, callback) ->
      body = {room: {topic: text}}
      self.put "/room/#{id}", body, callback

    sound: (text, callback) ->
      @message text, "SoundMessage", callback

    speak: (text, callback) ->
      body = { message: { "body":text } }
      self.post "/room/#{id}/speak", body, callback

    message: (text, type, callback) ->
      body = { message: { "body":text, "type":type } }
      self.post "/room/#{id}/speak", body, callback

    # listen for activity in channels
    listen: ->
      host = if self.custom then self.host else "streaming.campfirenow.com"
      headers =
        "Host"          : host
        "Authorization" : self.authorization
        "User-Agent"    : "Hubot/#{@robot?.version} (#{@robot?.name})"

      options =
        "agent"  : false
        "host"   : host
        "port"   : self.port
        "path"   : join_path self.prefix, "/room/#{id}/live.json"
        "method" : "GET"
        "headers": headers

      logger.debug "request: %s", json(options)

      request = self.http.request options, (response) ->
        response.setEncoding("utf8")
        contentType = response.headers['content-type']
        sse = contentType == "text/event-stream"

        buf = ''

        response.on "data", (chunk) ->
          if chunk is ' '
            # campfire api sends a ' ' heartbeat every 3s
            logger.debug "heartbeat"
            return

          logger.debug "data: %s", chunk

          if chunk.match(/^\s*Access Denied/)
            logger.error "Campfire error on room #{id}: #{chunk}"

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
                  room_id = data.room_id || data.body?.room_id
                  body = if data.body then data.body.body || data.body else {}
                  type = data.type || data.name
                  if type == "message"
                    type = "TextMessage"
                  self.emit(
                    type,
                    data.id,
                    data.created_at,
                    room_id,
                    data.user_id || data.actor,
                    body
                  )
                catch error
                  logger.error "Campfire data error: #{error}\n#{error.stack}"

        response.on "end", ->
          logger.error "Streaming connection closed for room #{id}. :("
          setTimeout ->
            self.emit "reconnect", id
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
      "path"   : join_path @prefix, path
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
              logger.error "Campfire status code: #{response.statusCode}"
              logger.error "Campfire response data: #{data}"

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

# TODO use lodash, urljoin packages
identity = (t) -> t
trim_slash = (s) ->
  if s.charAt(0) == '/'
    s = s.substr(1)
  if s.charAt(s.length - 1) == '/'
    s = s.substr(0, s.length - 1)
  return s

join_path = () ->
  args = [].slice.call(arguments)
  "/" + args.filter(identity).map(trim_slash).filter(identity).join("/")

pretty_json = true
json = (d) ->
  if pretty_json then JSON.stringify(d, null, 2) else JSON.stringify(d)

exports.EventStream = EventStream
