HTTP = require 'http'
HTTPS = require 'https'
{ EventEmitter } = require 'events'
{ Robot, Adapter, TextMessage, EnterMessage, LeaveMessage, TopicMessage } = require 'hubot'
{ Client } = require './client'

class CustomAdapter extends Adapter
  send: (envelope, strings...) ->
    if strings.length > 0
      string = strings.shift()
      if typeof(string) == 'function'
        string()
        @send envelope, strings...
      else
        @robot.logger.debug "send #{string} to thread #{envelope.room}"
        @bot.sendMessage envelope.room, string, (err, data) =>
          @robot.logger.error "send error: #{err}" if err?
          @send envelope, strings...

  emote: (envelope, strings...) ->
    @send envelope, strings.map((str) -> "*#{str}*")...

  reply: (envelope, strings...) ->
    @send envelope, strings.map((str) -> "#{envelope.user.name}: #{str}")...

  run: ->
    logger = @robot.logger
    logger.info "loading custom campfire adapter"
    self = @

    options =
      host: process.env.HUBOT_CHAT_HOST
      port: process.env.HUBOT_CHAT_PORT || 443
      token: process.env.HUBOT_CHAT_TOKEN

    bot = new Client(options, @robot)

    withAuthor = (callback) ->
      (id, created, room, user, body) ->
        bot.getUser user, (err, userData) ->
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

    bot.me (err, data) ->
      if err
        logger.error "cannot get user info: %s", err
        return

      user = data.user || data
      logger.info "loaded user info: %s", json(user)
      bot.info = user
      bot.name = user.name

      logger.info "listening all channels"
      bot.listen()

    @bot = bot

    self.emit "connected"

exports.CustomAdapter = CustomAdapter
