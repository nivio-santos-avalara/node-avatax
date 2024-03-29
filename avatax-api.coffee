# avatax-api.coffee
#
# AvaTax REST API utilities for CoffeeScript
#
# Copyright 2012 Avalara, Inc.
#
# Released under the MIT License.
# #######################################################
# author: Bryce Howard
# version: 0.1.0
#
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
    if config.Credentials?.user? and config.Credentials?.password?
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
  for prop in ['city','postalCode','region','country','addressCode']
    do (prop) =>
      @::[prop] = (value) ->
        unless value? then @["_#{prop}"]
        else @["_#{prop}"] = value; @

  # adds address "line", where each line added is ultimately
  # represented as "Line[#]" in request, where # is between 1 and 3
  line: (line) ->
    if line?
      @_lines ?= []
      throw new Error 'attempt to exceed maximum number of supported address lines (<= 3)' if @_lines.length is 3
      @_lines.push line ; return @
    @_lines

  # cobbles together all fields in one line and useless for presentation.
  # utilized for uniqueness constraint
  stringify: ->
    s = ''
    for own k,v of @
      s += v if v?.constructor is String
    s += line for line in @line() if @line()?

  # translates instance to a form that can be directly
  # serialized into a GetTax REST API request
  objectify: ->
    result =
      PostalCode: @postalCode()
      AddressCode: @addressCode() if @addressCode()?
      City: @city() if @city()?
      Region: @region() if @region()?
      Country: @_country if @country()?
    result["Line#{i + 1}"] = line for line,i in @line() if @line()?
    result

  # ensures all fields required by API are present
  validate: ->
    unless @postalCode()? or @country()?
      throw new Error 'Missing 1 or more required fields (postalCode and/or country)'
    @

# AvaTax GetTax request "LineItem" element
class OrderLine

  # generate setter/getters for simple properties
  # return current setting value if none supplied; "this" if supplied
  # (to support method chaining)
  for prop in ['lineNo','description','price','quantity']
    do (prop) =>
      @::[prop] = (value) ->
        unless value? then @["_#{prop}"]
        else @["_#{prop}"] = value; @

  constructor: -> @quantity(1)

  # set/get ship-to address
  destination: (address) ->
    if address?
      throw new Error 'incorrect type: expected Address' unless address instanceof Address
      @_destination = address.validate() ; return @
    @_destination

  # set/get ship-from address
  origin: (address) ->
    if address?
      throw new Error 'incorrect type: expected Address' unless address instanceof Address
      @_origin = address.validate() ; return @
    @_origin

  # ensures all fields required by API are present
  validate: ->
    for prop in ['lineNo','destination','origin','price','quantity']
      throw new Error "Missing required field [#{prop}]" unless @[prop]()?
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
      throw new Error 'incorrect type: expected Address' unless address instanceof Address
      @_addresses ?= []
      unless @_addresses[address.stringify()]?
        @_addresses[address.stringify()] = address.validate()
        # assign address code based upon index we decide for it within request
        # TODO this a possibly a bad idea. what if address is being shared between
        # instances of GetTax? quite possible given asynchronous modality of JS
        address.addressCode(@_addresses.length + 1)
      return @
    @_addresses

  # add a line item to request, or return all lines
  #
  # any unique addresses contained therein are added to request document
  # only valid line items will be accepted
  orderLine: (orderLine) ->
    if orderLine?.validate()
      throw new Error 'incorrect type: expected OrderLine' unless orderLine instanceof OrderLine
      @_orderLines ?= []
      @_orderLines.push orderLine
      @_address orderLine.origin()
      @_address orderLine.destination()
      return @
    @_orderLines

  # set/get transaction date
  orderDate: (date) ->
    if date?
      unless util.isDate(date) or date.constructor is String
        throw new Error 'incorrect type: expected Date or String'
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
    for prop in ['orderLine','orderDate','customerCode']
      throw new Error "Missing required field [#{prop}]" unless @[prop]()?
    @

  # translates instance GetTax REST API request document
  objectify: ->
    @validate()
    DocDate: @orderDate()
    CustomerCode: @customerCode()
    Addresses: v.objectify() for own k,v of @_addresses
    Lines:
      for line,i in @orderLine()
        LineNo: line.lineNo()
        # convert addresses to index reference form
        OriginCode: @_addresses[line.origin().stringify()].addressCode()
        DestinationCode: @_addresses[line.destination().stringify()].addressCode()
        Qty: line.quantity()
        Amount: line.quantity() * line.price()
        Description: line.description() if line.description()?

  # serialize request document
  jsonify: -> JSON.stringify @objectify()

  # issues an AvaTax GetTax REST API request
  #
  # success: callback invoked when encountering non-empty HTTP 200 response;
  #   invoked with response HTTP headers and deserialized results
  # error: callback invoked upon error; obstensibly passed Error instance
  request: (success,error) ->
    body = @jsonify()
    options = url.parse @_endpoint
    options.method = 'POST'
    options.headers =
      'Content-Length': body.length
      'Content-Type': 'text/json'
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
        # this would be weird, connection reset before HTTP transaction complete
        error? e
      .on 'end', ->
        # process response body
        #TODO but what if we've a non-200 status???
        unless response.statusCode is 200
          error?(new Error "Non-200 status [#{response.statusCode}]")
          r "ERROR: #{data.tostring()}"
        else
          success? response.headers, JSON.parse data.toString()
    .on 'error', (e) ->
      error? e
    .end body
    @

# being required or invoked from command-line?
if require.main isnt module
  exports.GetTax = GetTax
  exports.Address = Address
  exports.OrderLine = OrderLine
  exports.Config = Config
# invoked from command-line
else
  # simple test-case. expects external configuration (i.e. avatax-config.coffee)
  test = ->
    new GetTax().orderLine(
      new OrderLine(
      ).lineNo(1
      ).destination(
        new Address(
        ).postalCode '98110'
          #).country 'NL'
      ).origin(
        new Address(
        ).line('100 Ravine Lane NE'
        ).line('#220'
        ).postalCode '98110'
      ).price(10
      ).description 'Nike Air Jordans'
    ).orderDate(new Date
    ).customerCode('TEST'
    ).request (headers, reply) ->
        pp reply
      (e) -> r "error: #{e}"
  test()

