# AvaTax REST API integration library for node.js
minimal node.js integration library for the Avalara AvaTax REST API. supports only the GetTax operation, 
and of that only a limited number of fields. performs basic validation of request fields. has no dependencies to third-party utilities. 
tested and developed under node.js 0.7.9 and CoffeeScript 1.3.3. uses a static configuration scheme for credentials and API endpoint, see avatax-config.coffee.template.

AvaTax REST API GetTax documentation may be found at http://developer.avalara.com/api-docs/rest/resources/tax/get/ver-post/

# License
All files contained in this repository are released under the MIT license:
* http://www.opensource.org/licenses/MIT
