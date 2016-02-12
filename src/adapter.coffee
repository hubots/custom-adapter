HTTP = require 'http'
HTTPS = require 'https'
{ EventEmitter } = require 'events'
{ Robot, Adapter, TextMessage, EnterMessage, LeaveMessage, TopicMessage } = require 'hubot'
{ EventStream } = require './eventStream'

class CustomAdapter extends Adapter
  send: (envelope, strings...) ->
    if strings.length > 0
      string = strings.shift()
      if typeof(string) == 'function'
        string()
        @send envelope, strings...
      else
        @robot.logger.debug "send #{string} to room #{envelope.room}"
        @bot.Room(envelope.room).speak string, (err, data) =>
          @robot.logger.error "Campfire send error: #{err}" if err?
          @send envelope, strings...

  emote: (envelope, strings...) ->
    @send envelope, strings.map((str) -> "*#{str}*")...

  reply: (envelope, strings...) ->
    @send envelope, strings.map((str) -> "#{envelope.user.name}: #{str}")...

  topic: (envelope, strings...) ->
    @bot.Room(envelope.room).topic strings.join(" / "), (err, data) =>
      @robot.logger.error "Campfire topic error: #{err}" if err?

  play: (envelope, strings...) ->
    @bot.Room(envelope.room).sound strings.shift(), (err, data) =>
      @robot.logger.error "Campfire sound error: #{err}" if err?
      @play envelope, strings...

  locked: (envelope, strings...) ->
    if envelope.message.private
      @send envelope, strings...
    else
      @bot.Room(envelope.room).lock (args...) =>
        strings.push =>
          # campfire won't send messages from just before a room unlock. 3000
          # is the 3-second poll.
          setTimeout (=> @bot.Room(envelope.room).unlock()), 3000
        @send envelope, strings...

  run: ->
    logger = @robot.logger
    logger.info "loading custom campfire adapter"
    self = @

    options =
      host: process.env.HUBOT_CAMPFIRE_HOST
      port: process.env.HUBOT_CAMPFIRE_PORT || 443
      prefix: process.env.HUBOT_CAMPFIRE_APIPREFIX
      token: process.env.HUBOT_CAMPFIRE_TOKEN
      rooms: process.env.HUBOT_CAMPFIRE_ROOMS || ""
      account: process.env.HUBOT_CAMPFIRE_ACCOUNT

    bot = new EventStream(options, @robot)

    withAuthor = (callback) ->
      (id, created, room, user, body) ->
        bot.User user, (err, userData) ->
          user = userData.user || userData
          logger.debug "user info: %s", json(user)
          if user
            author = self.robot.brain.userForId(user.id, user)
            userId = user.id
            self.robot.brain.data
              .users[userId].name = user.name
            self.robot.brain.data
              .users[userId].email_address = user.email_address || user.email
            author.room = room
            callback id, created, room, user, body, author

    bot.on "TextMessage",
      withAuthor (id, created, room, user, body, author) ->
        unless bot.info.id is author.id
          message = new TextMessage author, body, id
          message.private = bot.private[room]
          self.receive message

    bot.on "EnterMessage",
      withAuthor (id, created, room, user, body, author) ->
        unless bot.info.id is author.id
          self.receive new EnterMessage author, null, id

    bot.on "LeaveMessage",
      withAuthor (id, created, room, user, body, author) ->
        unless bot.info.id is author.id
          self.receive new LeaveMessage author, null, id

    bot.on "TopicChangeMessage",
      withAuthor (id, created, room, user, body, author) ->
        unless bot.info.id is author.id
          self.receive new TopicMessage author, body, id

    bot.on "LockMessage",
      withAuthor (id, created, room, user, body, author) ->
        bot.private[room] = true

    bot.on "UnlockMessage",
      withAuthor (id, created, room, user, body, author) ->
        bot.private[room] = false

    bot.Me (err, data) ->
      if err
        logger.error "cannot get user info: %s", err
        return

      user = data.user || data
      logger.info "loaded user info: %s", json(user)
      bot.info = user
      bot.name = user.name

      unless bot.rooms and bot.rooms.length
        logger.info "listening all rooms"
        bot.Rooms (err, rooms) ->
          bot.rooms = rooms.map (t) -> t.id
          listenRooms()
        return

      listenRooms()

    listenRooms = () ->
      logger.info "listening rooms: %s", bot.rooms.join(",")
      for roomId in bot.rooms.filter(identity)
        do (roomId) ->
          room = bot.Room(roomId)
          return unless room
          room.join (err, callback) ->
            bot.Room(roomId).listen()

    bot.on "reconnect", (roomId) ->
      bot.Room(roomId).join (err, callback) ->
        bot.Room(roomId).listen()

    @bot = bot

    self.emit "connected"

exports.CustomAdapter = CustomAdapter
