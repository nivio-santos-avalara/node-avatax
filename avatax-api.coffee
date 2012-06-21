# CoffeeScript AvaTax REST API utilities
http = require 'http'
https = require 'https'
url = require 'url'
util = require 'util'

[p,w,r] = [console.log,console.warn,console.error]
pp = (o) -> p util.inspect o, true, null, true

# static configuration
class Config

  ProdEndpoint: 'https://rest.avalara.net/1.0/tax/get'
  DevEndpoint: ''
  Endpoint: @::ProdEndpoint

  # retrieve credentials and possible override for API endpoint
  try
    config = require './avatax-config'
    if config.Credentials? and config.Credentials.user? and config.Credentials.password?
      Credentials: config.Credentials
    else
      w 'missing AvaTax credentials in config file ... must be configured programmatically'
    Endpoint: config.Endpoint if config.Endpoint?
  catch e
    w 'no external AvaTax config found ... credentials must be configured programmatically'

# AvaTax GetTax request "Address" element
class Address

  # generate setter/getters for simple properties
  # return current setting value if none supplied; "this" if supplied
  # (to support method chaining)
  for prop in ['city', 'postalCode', 'region', 'country', 'addressCode']
    do (prop) =>
      @::[prop] = (value) ->
        unless value? then @["_#{prop}"]
        else @["_#{prop}"] = value; @

  constructor: (line, postalCode = undefined) ->
    @line line
    @postalCode postalCode

  # adds address "line", where each line added is ultimately
  # represented as "Line[#]" in request, where # is between 1 and 3
  line: (line) ->
    if line?
      @_lines = [] unless @_lines?
      throw new Error 'attempt to exceed maximum number of supported address lines (<= 3)' if @_lines.length == 3
      @_lines.push line ; return @
    @_lines

  # for purposes of hashing produces canonical representation of instance
  toString: ->
    s = ''
    for own name, value of @
      if value? and value.constructor is String
        s += value
      else if value? and name is '_lines' and @_lines?
        s += line for line in @_lines
    s

  # translates instance to form directly embeddable
  # in a GetTax REST API request
  toObject: ->
    result = PostalCode: @_postalCode
    for i in [0...@_lines.length]
      result["Line#{i + 1}"] = @_lines[i]
    result.AddressCode = @_addressCode if @_addressCode?
    result.City = @_city if @_city?
    result.Region = @_region if @_region?
    result.Country = @_country if @_country?
    result

  # ensures all fields required by API are present
  validate: ->
    unless @_postalCode? and @_lines?
      throw new Error 'Missing 1 or more required fields (line and postalCode)'
    @

# AvaTax GetTax request "LineItem" element
class OrderLine

  # fields required by API
  _required: ['dest','origin','price','qty']

  constructor: (price, origin = undefined, dest = undefined) ->
    @price price
    @origin origin
    @destination dest

  # quantity shipped/purchased
  quantity: (qty) ->
    if qty?
      @_qty = qty; return @
    @_qty

  # price of single unit
  price: (price) ->
    if price?
      @_price = price
      @_qty = 1 unless @_qty? ; return @
    @_price

  # set/get ship-to address
  destination: (address) ->
    if address?
      throw new Error 'incorrect type: expected Address' unless address.constructor is Address
      @_dest = address.validate() ; return @
    @_dest

  # set/get ship-from address
  origin: (address) ->
    if address?
      throw new Error 'incorrect type: expected Address' unless address.constructor is Address
      @_origin = address.validate() ; return @
    @_origin

  # ensures all fields required by API are present
  validate: ->
    for prop in @_required
      throw new Error "Missing required field [#{prop}]" unless @["_#{prop}"]?
    @

################################################################################
# AvaTax GetTax REST API request utility
# supports version 1.0 of the AvaTax REST API specification
################################################################################
class GetTax

  # _credentials: object defining "user" and "password" AvaTax credentials
  # _endpoint: AvaTax API endpoint URL
  constructor: (@_credentials = Config::Credentials, @_endpoint = Config::Endpoint) ->
    unless @_credentials?.user? and @_credentials?.password?
      throw new Error 'missing required AvaTax account credentials'

  # add unique Address instance to request, or return all unique addresses
  #
  # note: this does not associate Address with any line item, it serves
  #   to make addresses referrable at document-level. the AvaTax API
  #   expects all unique addresses to sit at top of document, and all line
  #   items make reference to these by index.
  _address: (address) ->
    if address?
      unless @_addresses?
        @_addresses = {}
        @_addrCount = 0
      throw new Error 'incorrect type: expected Address' unless address.constructor is Address
      unless @_addresses[address.toString()]?
        @_addresses[address.toString()] = address.validate()
        address.addressCode ++@_addrCount
      return @
    @_addresses

  # add a line item to request, or return all lines
  #
  # any unique addresses contained therein are added to request document
  # only valid line items will be accepted
  orderLine: (orderLine) ->
    if orderLine?
      @_orderLines = [] unless @_orderLines?
      throw new Error 'incorrect type: expected OrderLine' unless orderLine.constructor is OrderLine
      @_orderLines.push orderLine.validate()
      @_address orderLine.origin()
      @_address orderLine.destination()
      return @
    @_orderLines

  # set/get transation date
  orderDate: (date) ->
    if date?
      throw new Error 'incorrect type: expected Date or String' unless util.isDate(date) or date.constructor is String
      if util.isDate date
        @_orderDate = date.toJSON().match(/^\d+-\d+-\d+/)[0]
      else @_orderDate = date
      return @
    @_orderDate

  # set/get customer code
  customerCode: (customerCode) ->
    if customerCode?
      @_customerCode = customerCode; @
    else @_customerCode

  # ensures all fields required by API are present
  validate: ->
    unless @_orderLines? and @_orderDate? and @_customerCode?
      throw new Error 'Missing 1 or more required fields (orderLine, orderDate, customerCode)'
    @

  # translates instance GetTax REST API request document
  toObject: ->
    @validate()
    addresses = []
    # add all unique line item addresses
    for own name,address of @_addresses
      addresses.push address.toObject()
    # all line items
    lines = for line,i in @_orderLines
      LineNo: i + 1
      # convert addresses to index reference form
      OriginCode: @_addresses[line.origin().toString()].addressCode()
      DestinationCode: @_addresses[line.destination().toString()].addressCode()
      Qty: line.quantity()
      Amount: line.quantity() * line.price()
    # top-level of request document
    request =
      DocDate: @orderDate()
      CustomerCode: @customerCode()
      Addresses: addresses
      Lines: lines

  # serialize request document
  toJSON: -> JSON.stringify @toObject()

  # issues an AvaTax GetTax REST API request
  #
  # success: callback invoked when encountering non-empty HTTP 200 response;
  #   invoked with response HTTP headers and deserialized results
  # error: callback invoked upon error; obstensibly passed Error instance
  request: (success,error) ->
    body = @toJSON()
    options = url.parse @_endpoint
    options.method = 'POST'
    options.headers = 'Content-Length': body.length
    options.headers['Content-Type'] = 'text/json'
    options.auth = @_credentials.user + ':' + @_credentials.password
    # deal with eventuality that maybe using non-TLS API endpoint for testing
    protocol = if options.protocol is 'https:' then https else http
    protocol.request options, (response) ->
      # we are here because we have an HTTP response back from AvaTax API
      # ... but we've not read the body yet
      read = 0
      #TODO assert that content-length is defined and > 0
      # prepare buffer to read response body
      data = new Buffer parseInt(response.headers['content-length'])
      response.on 'data', (chunk) ->
        chunk.copy data, read
        read += chunk.length
      .on 'close', (e) ->
        # this would be weird, connecting reset before HTTP transaction complete
        error? e
      .on 'end', ->
        # process response body
        #TODO but what if we've a non-200 status???
        unless response.statusCode is 200
          error?(new Error "Non-200 status [#{response.statusCode}]")
          r "ERROR: #{data.toString()}"
        else
          success? response.headers, data.toString()
    .on 'error', (e) ->
      error? e
    .end body
    @

# being required or invoked from command-line?
if exports.main isnt module
  exports.GetTax = GetTax
  exports.Address = Address
  exports.OrderLine = OrderLine
  exports.Config = Config
# invoked from command-line
else
  # simple test-case. expects external configuration (i.e. avatax-config.coffee)
  test = ->
    new GetTax().orderLine(
      new OrderLine().destination(
        new Address()
          .line('435 Ericksen Avenue Northeast')
          .line('#250')
          .postalCode('98110')
      ).origin(
        new Address()
          .line('100 Ravine Lane NE')
          .line('#220')
          .postalCode('98110')
      ).price 10
    ).orderDate(new Date)
    .customerCode('TEST')
    .request(headers, reply) -> p reply.toString(),
      (e) ->
        r "error: #{e}"
  test()

