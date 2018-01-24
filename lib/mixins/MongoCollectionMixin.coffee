{MongoClient}   = require 'mongodb'
{GridFSBucket}  = require 'mongodb'
Parser          = require 'mongo-parse' #mongo-parse@2.0.2


###
```coffee
# in application when its need

module.exports = (Module)->
  class MongoCollection extends Module::Collection
    @inheritProtected()
    @module Module

    @include Module::MongoCollectionMixin

  MongoCollection.initialize()
```
###


module.exports = (Module)->
  {
    ANY
    NILL

    Collection
    # QueryableCollectionMixinInterface
    PromiseInterface
    Query
    Cursor
    MongoCursor
    LogMessage: {
      SEND_TO_LOG
      LEVELS
      DEBUG
    }
    Utils: { _, co, jsonStringify, moment }
  } = Module::

  _connection = null
  _consumers = null

  Module.defineMixin 'MongoCollectionMixin', (BaseClass = Collection) ->
    class extends BaseClass
      @inheritProtected()

      # @implements QueryableCollectionMixinInterface

      ipoCollection       = @private collection: PromiseInterface
      ipoBucket           = @private bucket: PromiseInterface

      wrapReference = (value)->
        if _.isString(value)
          if /^\@doc\./.test value
            value.replace '@doc.', ''
          else
            value.replace '@', ''
        else
          value

      @public connection: PromiseInterface,
        get: ->
          self = @
          _connection ?= co ->
            credentials = ''
            mongodb = self.getData().mongodb ? self.configs.mongodb
            { username, password, host, port, dbName } = mongodb
            if username and password
              credentials =  "#{username}:#{password}@"
            db_url = "mongodb://#{credentials}#{host}:#{port}/#{dbName}?authSource=admin"
            connection = yield MongoClient.connect db_url
            # console.log 'new connection created'
            yield return connection
          _connection

      @public collection: PromiseInterface,
        get: ->
          self = @
          @[ipoCollection] ?= co ->
            connection = yield self.connection
            yield return connection.collection self.collectionFullName()
          @[ipoCollection]

      @public bucket: PromiseInterface,
        get: ->
          self = @
          @[ipoBucket] ?= co ->
            mongodb = self.getData().mongodb ? self.configs.mongodb
            { dbName } = mongodb
            connection = yield self.connection
            voDB = connection.db "#{dbName}_fs"
            yield return new GridFSBucket voDB,
              chunkSizeBytes: 64512
              bucketName: 'binary-store'
          @[ipoBucket]

      @public onRegister: Function,
        default: ->
          @super()
          do => @connection
          _consumers ?= 0
          _consumers++
          # console.log 'consumers:', _consumers
          return

      @public @async onRemove: Function,
        default: ->
          @super()
          _consumers--
          if _consumers is 0
            connection = yield _connection
            yield connection.close(true)
            _connection = undefined
          # console.log 'consumers:', _consumers
          yield return

      @public @async push: Function,
        default: (aoRecord)->
          collection = yield @collection
          stats = yield collection.stats()
          snapshot = @serialize aoRecord
          @sendNotification(SEND_TO_LOG, "MongoCollectionMixin::push ns = #{stats.ns}, snapshot = #{jsonStringify snapshot}", LEVELS[DEBUG])
          yield collection.insertOne snapshot,
            w: "majority"
            j: yes
            wtimeout: 500
          return @normalize yield collection.findOne id: $eq: snapshot.id

      @public @async remove: Function,
        default: (id)->
          collection = yield @collection
          stats = yield collection.stats()
          @sendNotification(SEND_TO_LOG, "MongoCollectionMixin::remove ns = #{stats.ns}, id = #{id}", LEVELS[DEBUG])
          yield collection.deleteOne {id: $eq: id},
            w: "majority"
            j: yes
            wtimeout: 500
          yield return

      @public @async take: Function,
        default: (id)->
          collection = yield @collection
          stats = yield collection.stats()
          @sendNotification(SEND_TO_LOG, "MongoCollectionMixin::take ns = #{stats.ns}, id = #{id}", LEVELS[DEBUG])
          rawRecord = yield collection.findOne {id: $eq: id}
          if rawRecord?
            yield return @normalize rawRecord
          else
            yield return

      @public @async takeBy: Function,
        default: (query, options = {})->
          collection = yield @collection
          stats = yield collection.stats()
          voQuery = @parseFilter Parser.parse query
          @sendNotification(SEND_TO_LOG, "MongoCollectionMixin::takeBy ns = #{stats.ns}, voQuery = #{jsonStringify voQuery}", LEVELS[DEBUG])
          voNativeCursor = yield collection.find voQuery
          if (vnLimit = options.$limit)?
            voNativeCursor = voNativeCursor.limit vnLimit
          if (vnOffset = options.$offset)?
            voNativeCursor = voNativeCursor.skip vnOffset
          if (voSort = options.$sort)?
            voNativeCursor = voNativeCursor.sort voSort.reduce (result, item)->
              for own asRef, asSortDirect of item
                result[wrapReference asRef] = if asSortDirect is 'ASC'
                  1
                else
                  -1
              result
            , {}
          yield return MongoCursor.new @, voNativeCursor

      @public @async takeMany: Function,
        default: (ids)->
          collection = yield @collection
          stats = yield collection.stats()
          @sendNotification(SEND_TO_LOG, "MongoCollectionMixin::takeMany ns = #{stats.ns}, ids = #{jsonStringify ids}", LEVELS[DEBUG])
          voNativeCursor = yield collection.find {id: $in: ids}
          yield return MongoCursor.new @, voNativeCursor

      @public @async takeAll: Function,
        default: ->
          collection = yield @collection
          stats = yield collection.stats()
          @sendNotification(SEND_TO_LOG, "MongoCollectionMixin::takeAll ns = #{stats.ns}", LEVELS[DEBUG])
          voNativeCursor = yield collection.find()
          yield return MongoCursor.new @, voNativeCursor

      @public @async override: Function,
        default: (id, aoRecord)->
          collection = yield @collection
          snapshot = @serialize aoRecord
          stats = yield collection.stats()
          @sendNotification(SEND_TO_LOG, "MongoCollectionMixin::override ns = #{stats.ns}, id = #{id}, snapshot = #{jsonStringify snapshot}", LEVELS[DEBUG])
          yield collection.updateOne {id: $eq: id}, $set: snapshot,
            multi: yes
            w: "majority"
            j: yes
            wtimeout: 500
          rawRecord = yield collection.findOne {id: $eq: id}
          if rawRecord?
            yield return @normalize rawRecord
          else
            yield return

      @public @async includes: Function,
        default: (id)->
          collection = yield @collection
          stats = yield collection.stats()
          @sendNotification(SEND_TO_LOG, "MongoCollectionMixin::includes ns = #{stats.ns}, id = #{id}", LEVELS[DEBUG])
          return (yield collection.findOne {id: $eq: id})?

      @public @async exists: Function,
        default: (query)->
          collection = yield @collection
          stats = yield collection.stats()
          voQuery = @parseFilter Parser.parse query
          @sendNotification(SEND_TO_LOG, "MongoCollectionMixin::exists ns = #{stats.ns}, voQuery = #{jsonStringify voQuery}", LEVELS[DEBUG])
          return (yield collection.count voQuery) isnt 0

      @public @async length: Function,
        default: ->
          collection = yield @collection
          stats = yield collection.stats()
          @sendNotification(SEND_TO_LOG, "MongoCollectionMixin::length ns = #{stats.ns}", LEVELS[DEBUG])
          yield return stats.count

      buildIntervalQuery = (aoKey, aoInterval, aoIntervalSize, aoDirect)->
        voIntervalStart = aoInterval.startOf(aoIntervalSize).toISOString()
        voIntervalEnd = aoInterval.endOf(aoIntervalSize).toISOString()
        if aoDirect
          $and: [
            "#{aoKey}": $gte: voIntervalStart
            "#{aoKey}": $lt: voIntervalEnd
          ]
        else
          $not: $and: [
            "#{aoKey}": $gte: voIntervalStart
            "#{aoKey}": $lt: voIntervalEnd
          ]

      # @TODO Нужно добавить описание входных параметров опреторам и соответственно их проверку
      @public operatorsMap: Object,
        default:
          # Logical Query Operators
          $and: (def)-> $and: def
          $or: (def)-> $or: def
          $not: (def)-> $not: def
          $nor: (def)-> $nor: def # not or # !(a||b) === !a && !b

          # Comparison Query Operators (aoSecond is NOT sub-query)
          $eq: (aoFirst, aoSecond)->
            "#{wrapReference(aoFirst)}": $eq: wrapReference(aoSecond) # ==
          $ne: (aoFirst, aoSecond)->
            "#{wrapReference(aoFirst)}": $ne: wrapReference(aoSecond) # !=
          $lt: (aoFirst, aoSecond)->
            "#{wrapReference(aoFirst)}": $lt: wrapReference(aoSecond) # <
          $lte: (aoFirst, aoSecond)->
            "#{wrapReference(aoFirst)}": $lte: wrapReference(aoSecond) # <=
          $gt: (aoFirst, aoSecond)->
            "#{wrapReference(aoFirst)}": $gt: wrapReference(aoSecond) # >
          $gte: (aoFirst, aoSecond)->
            "#{wrapReference(aoFirst)}": $gte: wrapReference(aoSecond) # >=
          $in: (aoFirst, alItems)-> # check value present in array
            "#{wrapReference(aoFirst)}": $in: alItems
          $nin: (aoFirst, alItems)-> # ... not present in array
            "#{wrapReference(aoFirst)}": $nin: alItems

          # Array Query Operators
          $all: (aoFirst, alItems)-> # contains some values
            "#{wrapReference(aoFirst)}": $all: alItems
          $elemMatch: (aoFirst, aoSecond)-> # conditions for complex item
            "#{wrapReference(aoFirst)}": $elemMatch: aoSecond
          $size: (aoFirst, aoSecond)->
            "#{wrapReference(aoFirst)}": $size: aoSecond

          # Element Query Operators
          $exists: (aoFirst, aoSecond)-> # condition for check present some value in field
            "#{wrapReference(aoFirst)}": $exists: aoSecond
          $type: (aoFirst, aoSecond)->
            "#{wrapReference(aoFirst)}": $type: aoSecond

          # Evaluation Query Operators
          $mod: (aoFirst, aoSecond)->
            "#{wrapReference(aoFirst)}": $mod: aoSecond
          $regex: (aoFirst, aoSecond, aoThird)-> # value must be string. ckeck it by RegExp.
            [full, regexp, params] = /^\/([\s\S]*)\/(i?m?)$/i.exec aoSecond
            value = $regex: new RegExp regexp, params
            if aoThird?
              value["$options"] = aoThird
            "#{wrapReference(aoFirst)}": value
          $text: ()-> throw new Error 'Not supported'
          $where: ()-> throw new Error 'Not supported'

          # Datetime Query Operators
          $td: (aoFirst, aoSecond)-> # this day (today)
            buildIntervalQuery wrapReference(aoFirst), moment(), 'day', aoSecond
          $ld: (aoFirst, aoSecond)-> # last day (yesterday)
            buildIntervalQuery wrapReference(aoFirst), moment().subtract(1, 'days'), 'day', aoSecond
          $tw: (aoFirst, aoSecond)-> # this week
            buildIntervalQuery wrapReference(aoFirst), moment(), 'week', aoSecond
          $lw: (aoFirst, aoSecond)-> # last week
            buildIntervalQuery wrapReference(aoFirst), moment().subtract(1, 'weeks'), 'week', aoSecond
          $tm: (aoFirst, aoSecond)-> # this month
            buildIntervalQuery wrapReference(aoFirst), moment(), 'month', aoSecond
          $lm: (aoFirst, aoSecond)-> # last month
            buildIntervalQuery wrapReference(aoFirst), moment().subtract(1, 'months'), 'month', aoSecond
          $ty: (aoFirst, aoSecond)-> # this year
            buildIntervalQuery wrapReference(aoFirst), moment(), 'year', aoSecond
          $ly: (aoFirst, aoSecond)-> # last year
            buildIntervalQuery wrapReference(aoFirst), moment().subtract(1, 'years'), 'year', aoSecond

      @public parseFilter: Function,
        args: [Object]
        return: ANY
        default: ({field, parts = [], operator, operand, implicitField})->
          if field? and operator isnt '$elemMatch' and parts.length is 0
            customFilter = @delegate.customFilters[field]
            if (customFilterFunc = customFilter?[operator])?
              customFilterFunc.call @, operand
            else
              @operatorsMap[operator] field, operand
          else if field? and operator is '$elemMatch'
            @operatorsMap[operator] field, parts.reduce (result, part)=>
              if implicitField and not part.field? and (not part.parts? or part.parts.length is 0)
                subquery = @operatorsMap[part.operator] 'temporaryField', part.operand
                Object.assign result, subquery.temporaryField
              else
                Object.assign result, @parseFilter part
            , {}
          else
            @operatorsMap[operator ? '$and'] parts.map @parseFilter.bind @

      @public @async parseQuery: Function,
        default: (aoQuery)->
          if aoQuery.$join?
            throw new Error '`$join` not available for Mongo queries'
          if aoQuery.$let?
            throw new Error '`$let` not available for Mongo queries'
          if aoQuery.$aggregate?
            throw new Error '`$aggregate` not available for Mongo queries'

          voQuery = {}
          aggUsed = aggPartial = intoUsed = intoPartial = finAggUsed = finAggPartial = null
          isCustomReturn = no

          if aoQuery.$remove?
            if aoQuery.$forIn?
              # работа будет только с одной коллекцией, поэтому игнорируем
              voQuery.filter = {}
              voQuery.queryType = 'removeBy'
              if (voFilter = aoQuery.$filter)?
                voQuery.filter = @parseFilter Parser.parse voFilter
              isCustomReturn = yes
              voQuery
          else if aoQuery.$patch?
            if aoQuery.$into?
              voQuery.filter = {}
              voQuery.queryType = 'patchBy'
              if aoQuery.$forIn?
                # работа будет только с одной коллекцией, поэтому игнорируем $forIn
                if (voFilter = aoQuery.$filter)?
                  voQuery.filter = @parseFilter Parser.parse voFilter
              voQuery.patch = aoQuery.$patch
              isCustomReturn = yes
              voQuery
          else if aoQuery.$forIn?
            voQuery.queryType = 'query'
            voQuery.pipeline = []

            if (voFilter = aoQuery.$filter)?
              voQuery.pipeline.push $match: @parseFilter Parser.parse voFilter

            if (voSort = aoQuery.$sort)?
              voQuery.pipeline.push $sort: voSort.reduce (result, item)->
                for own asRef, asSortDirect of item
                  result[wrapReference asRef] = if asSortDirect is 'ASC'
                    1
                  else
                    -1
                result
              , {}

            if (vnOffset = aoQuery.$offset)?
              voQuery.pipeline.push $skip: vnOffset

            if (vnLimit = aoQuery.$limit)?
              voQuery.pipeline.push $limit: vnLimit

            if (voCollect = aoQuery.$collect)?
              isCustomReturn = yes
              collect = {}
              for own asRef, aoValue of voCollect
                do (asRef, aoValue)=>
                  collect[wrapReference asRef] = wrapReference aoValue

              into = if (vsInto = aoQuery.$into)?
                wrapReference vsInto
              else
                'GROUP'
              voQuery.pipeline.push $group:
                _id: collect
                "#{into}":
                  $push: Object.keys(@delegate.attributes).reduce (p, c)->
                    p[c] = "$#{c}"
                    p
                  , {}

            if (voHaving = aoQuery.$having)?
              voQuery.pipeline.push $match: @parseFilter Parser.parse voHaving

            if (aoQuery.$count)?
              isCustomReturn = yes
              voQuery.pipeline.push $count: 'result'

            else if (vsSum = aoQuery.$sum)?
              isCustomReturn = yes
              voQuery.pipeline.push $group:
                _id : null
                result: $sum: "$#{wrapReference vsSum}"
              voQuery.pipeline.push $project: _id: 0

            else if (vsMin = aoQuery.$min)?
              isCustomReturn = yes
              voQuery.pipeline.push $sort: "#{wrapReference vsMin}": 1
              voQuery.pipeline.push $limit: 1
              voQuery.pipeline.push $project:
                _id: 0
                result: "$#{wrapReference vsMin}"

            else if (vsMax = aoQuery.$max)?
              isCustomReturn = yes
              voQuery.pipeline.push $sort: "#{wrapReference vsMax}": -1
              voQuery.pipeline.push $limit: 1
              voQuery.pipeline.push $project:
                _id: 0
                result: "$#{wrapReference vsMax}"

            else if (vsAvg = aoQuery.$avg)?
              isCustomReturn = yes
              voQuery.pipeline.push $group:
                _id : null
                result: $avg: "$#{wrapReference vsAvg}"
              voQuery.pipeline.push $project: _id: 0

            else
              if (voReturn = aoQuery.$return)?
                if voReturn isnt '@doc'
                  isCustomReturn = yes
                if _.isString voReturn
                  if voReturn isnt '@doc'
                    voQuery.pipeline.push
                      $project:
                        _id: 0
                        "#{wrapReference voReturn}": 1
                else if _.isObject voReturn
                  vhObj = {}
                  projectObj = {}
                  for own key, value of voReturn
                    do (key, value)->
                      vhObj[key] = "$#{wrapReference value}"
                      projectObj[key] = 1
                  voQuery.pipeline.push $addFields: vhObj
                  voQuery.pipeline.push $project: projectObj

                if aoQuery.$distinct
                  voQuery.pipeline.push $group:
                    _id : '$$CURRENT'

          voQuery.isCustomReturn = isCustomReturn ? no
          yield return voQuery

      @public @async executeQuery: Function,
        default: (aoQuery, options)->
          collection = yield @collection
          stats = yield collection.stats()
          @sendNotification(SEND_TO_LOG, "MongoCollectionMixin::executeQuery ns = #{stats.ns}, aoQuery = #{jsonStringify aoQuery}", LEVELS[DEBUG])
          voNativeCursor = switch aoQuery.queryType
            when 'query'
              yield collection.aggregate aoQuery.pipeline, cursor: batchSize: 1
            when 'patchBy'
              yield collection.updateMany aoQuery.filter, $set: aoQuery.patch,
                multi: yes
                w: "majority"
                j: yes
                wtimeout: 500
              null
            when 'removeBy'
              yield collection.deleteMany aoQuery.filter,
                w: "majority"
                j: yes
                wtimeout: 500
              null

          voCursor = if aoQuery.isCustomReturn
            if voNativeCursor?
              MongoCursor.new null, voNativeCursor
            else
              Cursor.new null, []
          else
            MongoCursor.new @, voNativeCursor ? []
          return voCursor

      @public @async createFileWriteStream: Function,
        args: [Object]
        return: Object
        default: (opts) ->
          bucket = yield @bucket
          @sendNotification(SEND_TO_LOG, "MongoCollectionMixin::createFileWriteStream opts = #{jsonStringify opts}", LEVELS[DEBUG])
          yield return bucket.openUploadStream opts._id, {}

      @public @async createFileReadStream: Function,
        args: [Object]
        return: Object
        default: (opts) ->
          bucket = yield @bucket
          @sendNotification(SEND_TO_LOG, "MongoCollectionMixin::createFileReadStream opts = #{jsonStringify opts}", LEVELS[DEBUG])
          yield return bucket.openDownloadStreamByName opts._id, {}

      @public @async fileExists: Function,
        args: [Object]
        return: Boolean
        default: (opts, callback) ->
          bucket = yield @bucket
          @sendNotification(SEND_TO_LOG, "MongoCollectionMixin::fileExists opts = #{jsonStringify opts}", LEVELS[DEBUG])
          yield return (yield bucket.find filename: opts._id).hasNext()

      @public @async removeFile: Function,
        args: [Object]
        return: NILL
        default: (opts, callback) ->
          bucket = yield @bucket
          @sendNotification(SEND_TO_LOG, "MongoCollectionMixin::removeFile opts = #{jsonStringify opts}", LEVELS[DEBUG])
          cursor = yield bucket.find filename: opts._id
          if cursor.hasNext()
            yield bucket.delete cursor.next()._id
          yield return


      @initializeMixin()
