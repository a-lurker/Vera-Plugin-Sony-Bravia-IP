-- a-lurker, copyright, 31 March 2020

--[[
   Tested using openLuup on a Sony Bravia 'KDL 65W850C' TV. Year: 2015

   API:
   Functionality based on the Sony Bravia API:
   https://pro-bravia.sony.net/develop/index.html

   Notes:
   1) If the TV is powered completely off; a WOL packet will be required to get it started.
      This code requires the TV to be in Standby mode or at some other higher power level.
   2) Different models have different IR code sets. ie not all IR codes are always available.
   3) Some IR codes are replicated, so 'Sleep" and PowerOff' may be the same actual IR code.
      Other examples:
          Audio   & MediaAudioTrack
          PicOff  & PictureOff
          Analog2 & TvAnalog
          Input   & TvInput
          Num12   & Enter
   4) The actual IR codes sent are case sensitive. So these are different:
      'AAAAAQAAAAEAAAAUAw==' is Mute and 'AAAAAQAAAAEAAAAuAw==' is WakeUp

   Misc info:
   https://community.smartthings.com/t/new-sony-bravia-tv-integration-for-2015-2016-alpha

   https://helpguide.sony.net/gbmig/14HT0211/v1/eng/index_1_1.html
]]

--[[
   TV setup:
   1) Set up a static IP for the TV
   2) Enable Wake on LAN on your TV:    Settings → Network → Home Network Setup → Remote Start → On
   3) Enable pre-shared key on your TV: Settings → Network → Home Network Setup → IP Control → Authentication → Normal and Pre-Shared Key
   4) Set pre-shared key on your TV:    Settings → Network → Home Network Setup → IP Control → Pre-Shared Key → Enter your own PSK
   5) Enable Remote device/Renderer:    Settings → Network → Home Network Setup → Remote device/Renderer → Remote device/Renderer → On
   6) Enable Remote device/Renderer:    Settings → Network → Home Network Setup → Remote device/Renderer → Remote access control → Auto access permission → on
]]

--[[
    This program is free software; you can redistribute it and/or
    modify it under the terms of the GNU General Public License
    version 3 (GPLv3) as published by the Free Software Foundation;

    In addition to the GPLv3 License, this software is only for private
    or home usage. Commercial utilisation is not authorized.

    The above copyright notice and this permission notice shall be included
    in all copies or substantial portions of the Software.

    This program is distributed in the hope that it will be useful,
    but WITHOUT ANY WARRANTY; without even the implied warranty of
    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
    GNU General Public License for more details.
]]

local PLUGIN_NAME     = 'Sony_Bravia_IP'
local PLUGIN_SID      = 'urn:a-lurker-com:serviceId:'..PLUGIN_NAME..'1'
local PLUGIN_VERSION  = '0.52'
local THIS_LUL_DEVICE = nil

local PLUGIN_URL_ID   = 'al_sony_bravia_info'
local m_busy          = false

local m_psk           = ''   -- the TV's "preshared key" that you set up in the TV
local m_ipAddress     = ''   -- the TV's IP address
local m_macAddress    = ''   -- the TV's mac address
local m_connected     = false
local m_displayIsOn   = false
local m_json          = nil

-- Services that we can feed to getMethodTypes
-- There is also a getVersions call that be utilised
-- and maybe a getServiceProtocols call
-- (note that setting the service to 'ircc' returns no methods)
local knownServices = {
    'accessControl',
    'appControl',
    'audio',
    'avContent',
    'browser',
    'cec',
    'contentshare',
    'encryption',
    'guide',
    'notification',  -- ???? returns nothing on a 'KDL 65W850C'
    'recording',
    'system',
    'videoScreen',
}

-- Method to service mapping. See services listed above.
local serviceLookup = {
    getApplicationList         = 'appControl',
    getInterfaceInformation    = 'system',
    getPlayingContentInfo      = 'avContent',
    getPowerSavingMode         = 'system',
    getPowerStatus             = 'system',
    getRemoteControllerInfo    = 'system',
    getSchemeList              = 'avContent',
    getSourceList              = 'avContent',
    getSystemInformation       = 'system',
    getSystemSupportedFunction = 'system',
    getTextUrl                 = 'browser',
    getVolumeInformation       = 'audio',
    getWebAppStatus            = 'appControl',
    getWolMode                 = 'system',
    setActiveApp               = 'appControl',
    setAudioMute               = 'audio',
    setAudioVolume             = 'audio',
    setPlayContent             = 'avContent',
    setPowerStatus             = 'system',
    setTextForm                = 'appControl',
    terminateApps              = 'appControl',
}

-- InfraRed Compatible Control (IRCC) over Internet Protocol.
-- We have to POST these codes to make use of them, as the
-- REST API does not (for same strange reason) cater for them.
local m_irccIpCodes = {}

local socket = require('socket')
local http   = require('socket.http')
local ltn12  = require('ltn12')

-- don't change this, it won't do anything. Use the DebugEnabled flag instead
local DEBUG_MODE = true

local function debug(textParm, logLevel)
    if DEBUG_MODE then
        local text = ''
        local theType = type(textParm)
        if (theType == 'string') then
            text = textParm
        else
            text = 'type = '..theType..', value = '..tostring(textParm)
        end
        luup.log(PLUGIN_NAME..' debug: '..text,50)

    elseif (logLevel) then
        local text = ''
        if (type(textParm) == 'string') then text = textParm end
        luup.log(PLUGIN_NAME..' debug: '..text, logLevel)
    end
end

-- If non existent, create the variable. Update
-- the variable, only if it needs to be updated
local function updateVariable(varK, varV, sid, id)
    if (sid == nil) then sid = PLUGIN_SID      end
    if (id  == nil) then  id = THIS_LUL_DEVICE end

    if (varV == nil) then
        if (varK == nil) then
            luup.log(PLUGIN_NAME..' debug: '..'Error: updateVariable was supplied with nil values', 1)
        else
            luup.log(PLUGIN_NAME..' debug: '..'Error: updateVariable '..tostring(varK)..' was supplied with a nil value', 1)
        end
        return
    end

    local newValue = tostring(varV)
    debug(newValue..' --> '..varK)

    local currentValue = luup.variable_get(sid, varK, id)
    if ((currentValue ~= newValue) or (currentValue == nil)) then
        luup.variable_set(sid, varK, newValue, id)
    end
end

-- If possible, get a JSON parser. If none available, returns nil. Note that typically UI5 may not have a parser available.
local function loadJsonModule()
    local jsonModules = {
        'dkjson',               -- UI7 firmware
        'openLuup.json',        -- https://community.getvera.com/t/pure-lua-json-library-akb-json/185273
        'akb-json',             -- https://community.getvera.com/t/pure-lua-json-library-akb-json/185273
        'json',                 -- OWServer plugin
        'json-dm2',             -- dataMine plugin
        'dropbox_json_parser',  -- dropbox plugin
        'hue_json',             -- hue plugin
        'L_ALTUIjson',          -- AltUI plugin
        'cjson',                -- openLuup?
        'rapidjson'             -- how many json libs are there?
    }

    local ptr  = nil
    local json = nil
    for n = 1, #jsonModules do
        -- require does not load the module, if it's already loaded
        -- Vera has overloaded require to suit their requirements, so it works differently from openLuup
        -- openLuup:
        --    ok:     returns true or false indicating if the module was loaded successfully or not
        --    result: contains the ptr to the module or an error string showing the path(s) searched for the module
        -- Vera:
        --    ok:     returns true or false indicating the require function executed but require may have or may not have loaded the module
        --    result: contains the ptr to the module or an error string showing the path(s) searched for the module
        --    log:    log reports 'luup_require can't find xyz.json'
        local ok, result = pcall(require, jsonModules[n])
        ptr = package.loaded[jsonModules[n]]
        if (ptr) then
            json = ptr
            debug('Using: '..jsonModules[n])
            break
        end
    end
    if (not json) then debug('No JSON library found') return json end
    return json
end

-- Javascript for the plugin TV web page report and control
function htmlJavaScript()
return [[
<script type="text/javascript">

var URL           = '/port_3480/data_request';
var PLUGIN_URL_ID = 'al_sony_bravia_info';
var submitting    = false;

function ajaxRequest(url, args, onSuccess, onError) {
   // append any args to the url
   var first = true;
   for (var prop in args) {
      url += (first ? "?" : "&") + prop + "=" + args[prop];
      first = false;
   }

   // Internet Explorer (IE5 and IE6) use an ActiveX object instead of
   // the XMLHttpRequest object. We will not support those versions.
   var httpRequest = new XMLHttpRequest();
   if (!httpRequest) {
      alert('Cannot create httpRequest instance. Get an up-to-date browser!');
      return;
   }

   // Return the whole httpRequest object, so it can be picked
   // to pieces by the two callbacks as needed. Typically
   // ony responseText and responseXML will be of interest.
   httpRequest.onreadystatechange = function() {
        if (this.readyState == 4) {
            if (this.status != 200) {
                if (typeof onError == 'function') {
                    onError(this);
                }
            }
            else if (typeof onSuccess == 'function') {
                onSuccess(this);
            }
        }
   };

   // use GET and asynchronous operation
   httpRequest.open("GET", url, true);
   httpRequest.send();
}

// submission has completed
function okSubmitClicked()  { submitting = false; }
function errSubmitClicked() { submitting = false; }

// ----------------------------------------------------------------------------
// The "Submit" button was clicked
//
// Note that the submit button is of type "button", not type "submit"
// This disables submission of the form if javascript is not enabled.
// If the "submit" type button was used, the form could still be submitted
// without any validation being performed. We don't want that.
// ----------------------------------------------------------------------------

function submitClicked()
{
   // if the user gets a bit clicky, stop the form from being resubmitted, until we get a server response
   if (submitting) return false;

   // validate the text for the virtual keyboard entry box
   var textForm = encodeURIComponent(document.getElementById("textFormID").value);

   // send the text to the server
   submitting = true;
   var args = {
      id:         'lr_'+PLUGIN_URL_ID,
      fnc:        'setTextForm',
      textForm:    textForm,
      random:      Math.random()
      };

   ajaxRequest(URL, args, okSubmitClicked, errSubmitClicked);

   // the button is not to perform any further actions
   return false;
}

function sendRemoteCode(element,remoteCode)
{
   var args = {
      id:         'lr_'+PLUGIN_URL_ID,
      fnc:        'sendRemoteCode',
      remoteCode: remoteCode,
      random:     Math.random()
      };
   // no callbacks required
   ajaxRequest(URL, args, null, null);
   element.style.color = 'red';
}

function setActiveApp(element,uri)
{
   uri = encodeURIComponent(uri);
   var args = {
      id:     'lr_'+PLUGIN_URL_ID,
      fnc:    'setActiveApp',
      uri:    uri,
      random: Math.random()
      };

   // no callbacks required
   ajaxRequest(URL, args, null, null);
   element.style.color = 'red';
}

function okGetMethodTypes(httpRequest)
{
   document.getElementById("methodsID").innerHTML = httpRequest.responseText;
}

function getMethodTypes(element,service)
{
   var args = {
      id:      'lr_'+PLUGIN_URL_ID,
      fnc:     'getMethodTypes',
      service: service,
      random:  Math.random()
      };

   ajaxRequest(URL, args, okGetMethodTypes, null);
   element.style.color = 'red';
}

function startUp() {
   document.getElementById("submitBtnID").onclick = submitClicked;
   //document.getElementById("textFormID").focus();
}

// execute this
window.onload = startUp;

</script>]]
end

-- Read a boolean variable
local function readBoolVar(boolVar)
    local result = luup.variable_get(PLUGIN_SID, boolVar, THIS_LUL_DEVICE)
    if ((result == nil) or (result == '') or (result == '0')) then return false end
    return true
end

-- Write a boolean variable. Return the result for debugging purposes.
local function writeBoolVar(boolVar, status)
    local statusStr = '1'
    if (status) then
        updateVariable(boolVar,statusStr)
        return statusStr
    end

    statusStr = '0'
    updateVariable(boolVar, statusStr)
    return statusStr
end

-- Refer also to: http://w3.impa.br/~diego/software/luasocket/http.html
local function urlRequest(url, request_body)
    http.TIMEOUT = 1

    local response_body = {}
    local headers = {
        ['Content-Type']   = 'text/xml; charset=UTF-8',
        ['Content-Length'] = string.len(request_body),
        ['X-Auth-PSK']     = m_psk,    -- send this header, even if it's not needed; used by the PSK
        ["SOAPACTION"]     = '"urn:schemas-sony-com:service:IRCC:1#X_SendIRCC"'   -- ditto; used by IRCC
    }

    -- site not found: r is nil, c is the error status eg (as a string) 'No route to host' and h is nil
    -- site is found:  r is 1, c is the return status (as a number) and h are the returned headers in a table variable
    local r, c, h = http.request {
          url     = url,
          method  = 'POST',
          headers = headers,
          source  = ltn12.source.string(request_body),
          sink    = ltn12.sink.table(response_body)
    }

    debug('URL request result: r = '..tostring(r))
    debug('URL request result: c = '..tostring(c))
    debug('URL request result: h = '..tostring(h))

    local page = ''
    if (r == nil) then return false, page, 'Check ip address and connection' end

    if ((c == 200) and (type(response_body) == 'table')) then
        page = table.concat(response_body)
        debug('Returned TV data is : '..page)
        return true, page, 'All OK'
    end

    if (c == 400) then
        luup.log(PLUGIN_NAME..' debug: HTTP 400 Bad Request', 1)
        return false, page, 'HTTP 400 Bad Request'
    end

    if (c == 403) then
        luup.log(PLUGIN_NAME..' debug: HTTP 403 Forbidden - the Pre-Shared Key is probably not set up correctly', 1)
        return false, page, 'The Pre-Shared Key is probably not set up correctly'
    end

    if (c == 404) then
        luup.log(PLUGIN_NAME..' debug: HTTP 404 Page Not Found - the service name may be invalid', 1)
        return false, page, 'HTTP 404 Page Not Found - the service name may be invalid'
    end

    if (c == 500) then
        luup.log(PLUGIN_NAME..' debug: HTTP  500 Internal Server Error - probably the TV cannot satisfy the request: eg because it is turned off', 1)
        return false, page, 'HTTP 500 Internal Server Error'
    end

    return false, page, 'Unknown error'
end

-- Send a request to the TV's IRCC API
local function sendToIRCC(irCode)
    if ((not irCode) or (irCode == '')) then debug('IR code is nil or an empty string') return end
    local irCodeStr = m_irccIpCodes[irCode:lower()]
    if (not irCodeStr) then debug('IR code: '..irCode..' not found in m_irccIpCodes at 2. Code not sent.') return end

    debug('Sending code: '..irCode..': '..irCodeStr)

    local url = 'http://'..m_ipAddress..'/sony/ircc'
    local txMsg = [[
<?xml version="1.0"?>
<s:Envelope
    xmlns:s="http://schemas.xmlsoap.org/soap/envelope/"
    s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/">
    <s:Body>
        <u:X_SendIRCC xmlns:u="urn:schemas-sony-com:service:IRCC:1">
            <IRCCCode>]]..irCodeStr..[[</IRCCCode>
        </u:X_SendIRCC>
    </s:Body>
</s:Envelope>]]

    debug('Sending: '..txMsg)

    local success, returnedPage, errMsg = urlRequest(url, txMsg)
end

-- Send a request to the TV's API
local function sendToAPI(method, params, service)
    if (not service) then service = serviceLookup[method] end
    if (not service) then debug('Service not found in serviceLookup table ') service = '' end
    local url = 'http://'..m_ipAddress..'/sony/'..service
    local msgTab = {
        method  = method,
        id      = 1,
        params  = params or {},
        version = '1.0'
    }
    local txMsg = m_json.encode(msgTab)  -- encode:  obj to json txt

    debug('Sending: /sony/'..service..'/'..method..'('..txMsg..')')

    local success, returnedJson, errMsg = urlRequest(url, txMsg)

    local jsonObj = nil
    local strTab = {method..':'}
    if (not success) then
        table.insert(strTab, '\t'..errMsg)
        return success, jsonObj, strTab
    end

    jsonObj = m_json.decode(returnedJson)   -- failed decode returns nil; an empty table has a length of zero
    if (jsonObj and jsonObj.error) then
        success = false
        table.insert(strTab, '\tRequest returned an error msg:')
        table.insert(strTab, '\t'..jsonObj.error[1]..': '..jsonObj.error[2])
    end

    return success, jsonObj, strTab
end

-- Get the TV info: the json returned from the TV is only nested one deep
local function getSimpleResult(method, params)
    local success, jsonObj, strTab = sendToAPI(method, params)
    local resultTab = {}
    if (success) then
        -- tostring() is required, as at least value is a boolean
        -- eg getVolumeInformation returns: string, integer and boolean
        for k,v in pairs(jsonObj.result[1]) do
            resultTab[k] = v
            table.insert(strTab, '\t'..k..': '..tostring(v))
        end
    end
    return success, resultTab, table.concat(strTab,'\n')..'\n'
end

-- Get the TV info: the json returned from the TV is nested two deep
local function getNestedResult(method, params)
    local success, jsonObj, strTab = sendToAPI(method, params)
    local resultTab = {}
    if (success) then
        for k,v in ipairs(jsonObj.result[1]) do
            local tmpTab = {}
            resultTab[k] = {}
            -- tostring() is required, as at least one value is a boolean
            -- eg getVolumeInformation returns: string, integer and boolean
            for k1,v1 in pairs(v) do
                table.insert(tmpTab, '\t'..k1..': '..tostring(v1))
                resultTab[k][k1] = v1
            end
            table.insert(strTab,table.concat(tmpTab,'\n')..'\n')
        end
    end
    return success, resultTab, table.concat(strTab,'\n')..'\n'
end

-- Get the info for the web page: the json returned from the TV is only nested one deep
-- no 'params' need to be passed to the sendToAPI function
local function getSimpleResultForWebPage(method)
    local _, _, webPageTab = getSimpleResult(method)
    return webPageTab
end

-- Get the info for the web page: the json returned from the TV is nested two deep
-- no 'params' need to be passed to the sendToAPI function
local function getNestedResultForWebPage(method)
    local _, _, webPageTab = getNestedResult(method)
    return webPageTab
end

-- Get the TV's MAC address using the arp command
local function getMacAddress(ipAddress)
    -- capture the stdout data
    local pipeOut   = assert(io.popen('arp -n '..ipAddress, 'r'))
    local outputStr = assert(pipeOut:read('*a'))
    pipeOut:close()
    local macAddress = outputStr:match('(%x%x:%x%x:%x%x:%x%x:%x%x:%x%x)') or outputStr:match('(%x%x%-%x%x%-%x%x%-%x%x%-%x%x%-%x%x)')
    return macAddress
end

-- Get all the IR codes for the web page
-- Load up m_irccIpCodes for later use.
local function getRemoteControllerInfo()
    local success, jsonObj, strTab = sendToAPI('getRemoteControllerInfo')
    if (success) then
        strTab = {
            'getRemoteControllerInfo:',
            '\tClick on any blue highlight to send the associated IR code to the TV:\n'
        }
        -- sort the IR codes by name. An example of each array element k,v:
        -- jsonObj.result[2][k] = {"name":"Num1","value":"AAAAAQAAAAEAAAAAAw=="}
        table.sort(jsonObj.result[2], function (a,b) return a.name:lower() < b.name:lower() end)
        for _,v in ipairs(jsonObj.result[2]) do
            table.insert(strTab, '\t'..v.value..' '..'<span style="color:blue" onclick="sendRemoteCode(this,\''..v.name..'\')">'..v.name..'</span>')
            m_irccIpCodes[v.name:lower()] = v.value
        end
    end
    if (type(strTab) == 'string') then return strTab end   -- an error msg has been returned as string
    return table.concat(strTab,'\n')..'\n'
end

-- Get all the available applications for the web page
local function getApplicationList()
    local success, applications, strTab = getNestedResult('getApplicationList')
    if (success) then
        strTab = {
            'getApplicationList:',
            '\tClick on any blue highlight to run the application on the TV:\n'
        }
        -- sort the applications by title. An example of each array element k,v:
        -- applications[k] = {"title": "theTitle", "uri": "theURI", "icon": "theIcon"}
        table.sort(applications, function (a,b) return a.title:lower() < b.title:lower() end)

        -- ensure the order is as follows:
        --  [1] = "title": "theTitle"
        --  [2[ = "uri":   "theURI"
        --  [3] = "icon":  "theIcon"
        -- this seems overly complex but I found it tricky to reduce
        for _,eachApp in ipairs(applications) do
            local idx      = 0
            local titleIdx = 1
            local uriIdx   = 2
            local iconIdx  = 3
            local anyExtra = iconIdx
            local tmpArray = {}
            for k,v in pairs(eachApp) do
                if     (k == 'title') then idx = titleIdx
                elseif (k == 'uri')   then idx = uriIdx
                else
                   idx      = anyExtra
                   anyExtra = anyExtra+1
                end
                tmpArray[idx]   = {}
                tmpArray[idx].k = k
                tmpArray[idx].v = v
            end
            tmpArray[titleIdx].v = '<span style="color:blue" onclick="setActiveApp(this,\''..tmpArray[uriIdx].v..'\')">'..tmpArray[titleIdx].v..'</span>'

            local tmpTab = {}
            for k1,v1 in ipairs(tmpArray) do
                table.insert(tmpTab, '\t'..tmpArray[k1].k..': '..tmpArray[k1].v)
            end
            table.insert(strTab,table.concat(tmpTab,'\n')..'\n')
        end
    end
    if (type(strTab) == 'string') then return strTab end   -- an error msg has been returned as string
    return table.concat(strTab,'\n')..'\n'
end

-- Get all the schemes and the associated sources for each scheme to show on the the web page
local function getSchemesAndSources()
    local strTab = {'getSchemeList then getSourceList:'}
    local success, schemes = getNestedResult('getSchemeList')
    for _,v in pairs(schemes) do
        table.insert(strTab, '\t'..v.scheme..':')
        local success, schemeSources = getNestedResult('getSourceList', {{scheme = v.scheme}})
        for _,v1 in pairs(schemeSources) do
            -- never heard of a 'widi'? That would be a keyboard miss hit for 'wifi'
            table.insert(strTab, '\t\t'..v1.source)
        end
    end
    return table.concat(strTab,'\n')..'\n'
end

-- Get the methods that the TV supports for the web page.
local function getMethodTypes(service)
    -- Get all versions of the available methods. The second parameter
    -- can be used to filter the methods by version: {"1.0"} or {"1.1"}
    local success, jsonObj, strTab = sendToAPI('getMethodTypes', {""}, service)

    strTab[1] = strTab[1]..' service = '..service..':\n'
    if (success) then
        for _,v in ipairs(jsonObj.results) do
            table.insert(strTab, '\t'..v[1])
            for _,v1 in pairs(v[2]) do
                table.insert(strTab, '\t'..v1)
            end
            for _,v2 in pairs(v[3]) do
                table.insert(strTab, '\t'..v2)
            end
            table.insert(strTab, '\t'..v[4]..'\n')
       end
    end
    return table.concat(strTab,'\n')..'\n',"text/xml"
end

-- Shows all the services that getMethodTypes knows about
local function getMethodTypesServices()
    local strTab = {
        'getMethodTypes:',
        '\tClick on any blue highlight to get the methods available for each listed service:\n'
    }
    for _,v in ipairs(knownServices) do
        table.insert(strTab, '\t<span style="color:blue" onclick="getMethodTypes(this,\''..v..'\')">'..v..'</span>')
    end
    table.insert(strTab, '\n<span id="methodsID"></span>')

    return table.concat(strTab,'\n')..'\n'
end

-- As soon as the link goes from not m_connected to m_connected, the
-- config is retrieved and the connection status is set to true
local function getConfig()
    -- if connected no need to continue
    if m_connected then return end

    -- if we are not connected we call this every 30 seconds until
    -- it returns success. We then consider that we are connected.
    -- We can always retrieve this, regardless of the power status.
    local success, resultTab = getSimpleResult('getSystemInformation')

    -- still not connected?
    if (not (success and resultTab)) then return end

    -- we're connected! Get some config info
    updateVariable('Model', resultTab.model)

    -- this loads the table (m_irccIpCodes) with the IR codes the TV has available
    getRemoteControllerInfo()

    m_connected = true
    writeBoolVar('Connected', m_connected)

    debug('Successful execution of getConfig')
end

-- Get the status every 30 seconds, while simultaneously
-- checking if the network connection is still OK.
-- This function needs to be global, so the timer's timeOut can find it.
function monitorSonyBravia()
    -- As soon as the link is up, the TV config is
    -- retrieved and the connection status is set to true.
    -- If it goes down, the connection status is set to false
    -- after a one second timeout.

    -- check if the TV is connected by trying to retrieve the TV model info and IR codes:
    getConfig()

    -- only get the ongoing status if the link is up
    if not m_connected then return end

    -- update the TV's status if the link is up
    -- start with the 'active' vs 'standby' power status
    local success, resultTab = getSimpleResult('getPowerStatus')

    -- failure indicates the connection has gone down
    if (not (success and resultTab)) then
        m_connected = false
        writeBoolVar('Connected', m_connected)

        -- get the status every 30 seconds
        luup.call_delay('monitorSonyBravia', 30, '')
        return
    end

    -- The power status is either 'active' or 'standby'
    -- The status is changed by the user powering on the TV using the physical remote control or executing an
    -- equivalent power on IRCC-IP call. Calling the setPowerStatus() API method also achieves the same result.
    -- Likewise the setActiveApp() API method will change the status.
    m_displayIsOn = (resultTab.status == 'active')

    if (m_displayIsOn) then
        updateVariable('DisplayIsOn', '1')
        local success, resultTab = getNestedResult('getVolumeInformation')
        if (success and resultTab) then
            for _,v in ipairs(resultTab) do
                if (v.target == 'speaker') then
                    updateVariable('Volume', tostring(v.volume))
                    debug('Volume: '..v.volume)
                    local statusStr = writeBoolVar('Mute',v.mute)
                    debug('Mute: '..statusStr)
                end
            end
        end
    else
        -- m_displayIsOn must be true for the
        -- volume and mute info to be accessible.
        -- No display then there's no sound either
        updateVariable('DisplayIsOn', '0')
        updateVariable('Volume', '0')
        updateVariable('Mute', '0')
    end

    -- get the status every 30 seconds
    luup.call_delay('monitorSonyBravia', 30, '')
end

-- Proforma header for the web page
local function htmlHeader()
return [[<!DOCTYPE html PUBLIC "-//W3C//DTD XHTML 1.0 Strict//EN"
    "http://www.w3.org/TR/xhtml1/DTD/xhtml1-strict.dtd">
<html xmlns="http://www.w3.org/1999/xhtml" xml:lang="en" lang="en">
<head>
<meta http-equiv="content-type" content="text/html; charset=utf-8"/>]]
end

-- Web page used to report the TV's info. It can also control some aspects of the TV.
local function htmlIntroPage()

    local title  = 'Sony Bravia'
    local header = PLUGIN_NAME..':&nbsp;&nbsp;plugin version:&nbsp;&nbsp;'..PLUGIN_VERSION

    local strTab = {
    htmlHeader(),
    '<title>'..title..'</title>',
    htmlJavaScript(),
    '</head>\n',
    '<body>',
    '<h3>'..header..'</h3>',
    '<div>',
    'Your text for the onscreen virtual keyboard entry box --> <input id="textFormID" type="text" name="textForm" value=""/>',
    '<input id="submitBtnID" type="button" name="submitBtn" value="Submit"/><br/><br/>',
    '<pre>',
    getSimpleResultForWebPage('getPowerStatus'),
    getApplicationList(),
    getRemoteControllerInfo(),
    getNestedResultForWebPage('getVolumeInformation'),
    getSimpleResultForWebPage('getPlayingContentInfo'),
    getSchemesAndSources(),
    getSimpleResultForWebPage('getSystemInformation'),
    getSimpleResultForWebPage('getWolMode'),
    getSimpleResultForWebPage('getPowerSavingMode'),
    getMethodTypesServices(),

    -- some other calls tried out:
    -- getSimpleResultForWebPage('getTextUrl'),
    -- getSimpleResultForWebPage('getInterfaceInformation'),
    -- getNestedResultForWebPage('getSystemSupportedFunction'),
    -- getSimpleResultForWebPage('getWebAppStatus'),
   '</pre>',
    '</div>',
    '</body>',
    '</html>\n'
    }

    return table.concat(strTab,'\n'), 'text/html'
end

-- A service in the implementation file
-- Execution a TV function as requested by the user. The
-- user has to examine the log file to see what happened.
local function executeMethod(theMethod, theJson, theService)
    -- execute any function specified by the user
    local success, jsonObj, strTab = sendToAPI(theMethod, theJson, theService)
end

-- A service in the implementation file
-- Using IRCC, send an IRcode to the TV. Parameter remoteCode is the code
-- 'name' or the actual code which must begin with AAAAA and end with Aw==
local function sendRemoteCode(remoteCode)
    remoteCode = remoteCode or ''

    -- Was the code 'name' or the 'actual' code supplied in the passed in parameter?
    -- Check for an actual code and do a reverse search to get the code's 'name'.
    -- The actual codes are case sensitive. They begin with AAAAA and end with Aw==
    if (remoteCode:find('^AAAAA%a%a%a%a%a%a%a%a%a%a%aAw==$')) then
        -- an actual code value rather, than a code name was supplied
        local found = false
        for k,v in pairs(m_irccIpCodes) do
            if (v == remoteCode) then remoteCode = k found = true end
        end
        if (not found) then debug('IR code: '..remoteCode..' not found in m_irccIpCodes at 1. Code not sent.') return end
    end

    debug(remoteCode)
    sendToIRCC(remoteCode)
end

-- A service in the implementation file
-- Send the Wake On LAN packet to the TV. The TV needs the appropriate
-- options to be set, to allow the packet to be recognized and acted upon.
local function sendWOL()
    local result = m_macAddress:match('^(%x%x:%x%x:%x%x:%x%x:%x%x:%x%x)$') or m_macAddress:match('^(%x%x%-%x%x%-%x%x%-%x%x%-%x%x%-%x%x)$')
    if (result) then
        local command = '"wol '..m_macAddress..'"'
        debug ('Sending Wake On LAN command: '..command)
        os.execute (command)
    end
end

--[[
    A service in the implementation file
    Launch an application. The URI is made up of three parts 1,2 & 3 eg:
    com.sony.dtv.com.google.android.youtube.tv.com.google.android.apps.youtube.tv.activity.ShellActivity
     1) preamble:         com.sony.dtv.
     2) the application   com.google.android.youtube.tv.
     3) the activity:     com.google.android.apps.youtube.tv.activity.ShellActivity

    If the screen is in 'Standby' this command actives the screen but a timeout occurs before a response is rx'ed.
]]
local function setActiveApp(uri)
    if (uri:find('^com%.sony%.dtv%.')) then
        sendToAPI('setActiveApp', {{uri = uri}})
    end
end

-- A service in the implementation file
-- Allowed values: '0', '1' and 'T' for toggle
local function setMute(muteStr)
    -- the Volume & Mute can't be altered if the display is off
    if (not m_displayIsOn) then return end

    if (not((muteStr == '0') or (muteStr == '1') or (muteStr:upper() == 'T'))) then return end

    local mute = false
    if (muteStr:upper() == 'T') then -- toggle mute
        muteStr = luup.variable_get(PLUGIN_SID, 'Mute', THIS_LUL_DEVICE)
        mute = (muteStr == '0')
    else
        mute = (muteStr == '1')
    end

    -- Note we should really update the volume when we unmute. But
    -- heh! too bad, we'll rely on the function monitorSonyBravia.
    if (mute) then updateVariable('Volume', '0') end

    sendToAPI('setAudioMute', {{status = mute}})
    writeBoolVar('Mute', mute)
end

-- A service in the implementation file
-- Allowed string values are those returned by getSchemeList then getSourceList
-- The uri is case sensitive!!
-- An example uri:  'extInput:hdmi?port=1'
local function setPlayContent(uri)
    sendToAPI('setPlayContent', {{uri = uri}})
end

-- A service in the implementation file
-- Allowed values: '0' and '1'
local function setPower(powerStr)
    if ((powerStr ~= '0') and (powerStr ~= '1')) then return end

    -- setPowerStatus() returns either 'active' or 'standby' but
    -- the setter call setPowerStatus() uses true or false
    local power = (powerStr == '1')
    sendToAPI('setPowerStatus', {{status = power}})
    writeBoolVar('DisplayIsOn', power)
end

-- A service in the implementation file
-- Instead of using the infuriating onscreen virtual keyboard, we can just
-- directly inject text into the onscreen entry box with this call.
local function setTextForm(text)
    debug(text)
    sendToAPI('setTextForm', {text})
end

-- A service in the implementation file
-- Volume is 0 to 100 as a number or string
local function setVolume(volume)
    -- the Volume & Mute can't be altered if the display is off
    if (not m_displayIsOn) then return end

    volume = tonumber(volume)
    if ((volume == nil) or (volume < 0) or (volume > 100)) then return end

    volumeStr = tostring(volume)
    sendToAPI('setAudioVolume', {{target = 'speaker', volume = volumeStr}})
    updateVariable('Volume', volumeStr)
end

-- A service in the implementation file
-- Only increments of +/- 1, 2, 5 and 10 are allowed
local function setVolumeUpDown(step)
    -- the Volume & Mute can't be altered if the display is off
    if (not m_displayIsOn) then return end

    step = tonumber(step)
    if (step == nil) then return end

    local stepAbs = math.abs(step)
    if ((stepAbs ~= 2) and (stepAbs ~= 5) and (stepAbs ~= 10)) then return end

    -- Adding a preceding +/- to the volume level string
    -- indicates a relative step up or down is being requested.
    local stepStr = tostring(step)
    -- if step is negative, it will already be proceeded by
    -- a minus sign, so stepStr will already be as needed
    if (step > 0) then stepStr = '+'..stepStr end
    sendToAPI('setAudioVolume', {{target = 'speaker', volume = stepStr}})

    local volumeStr = luup.variable_get(PLUGIN_SID, 'Volume', THIS_LUL_DEVICE)
    local volume = tonumber(volumeStr)
    volume = volume + step
    if (volume < 0)    then volume = 0   end
    if (volume > 100)  then volume = 100 end
    volumeStr = tostring(volume)
    updateVariable('Volume', volumeStr)
end

-- A service in the implementation file
-- Close all running apps eg YouTube, Netflix, etc and show the 'Home' screen
local function terminateApps()
    sendToAPI('terminateApps')
end

-- Entry point for all html page requests and all ajax function calls
-- http://vera_ip_address/port_3480/data_request?id=lr_al_sony_bravia_info
function requestMain (lul_request, lul_parameters, lul_outputformat)
    debug('request is: '..tostring(lul_request))
    for k, v in pairs(lul_parameters) do debug ('parameters are: '..tostring(k)..'='..tostring(v)) end
    debug('outputformat is: '..tostring(lul_outputformat))

    if not (lul_request:lower() == PLUGIN_URL_ID) then return end

    -- get the parameter keys to lower case but leave the values
    -- as is: the values need to maintain the case as supplied
    local lcParameters = {}
    for k, v in pairs(lul_parameters) do lcParameters[k:lower()] = v end

    -- if no function is requested in the url parameters then output the intro page
    if not lcParameters.fnc then
        if (m_busy) then return '' else m_busy = true end
        local page = htmlIntroPage()
        m_busy = false
        return page
    end

    -- call any function that may be specified in the url parameters
    -- the URI encoded textForm parameter has already been decoded at this point by the server
    if (lcParameters.fnc:lower() == 'getmethodtypes') then return getMethodTypes(lcParameters.service)    end
    if (lcParameters.fnc:lower() == 'sendremotecode') then return sendRemoteCode(lcParameters.remotecode) end
    if (lcParameters.fnc:lower() == 'setactiveapp')   then return setActiveApp(lcParameters.uri)          end
    if (lcParameters.fnc:lower() == 'settextform')    then return setTextForm(lcParameters.textform)      end

    return 'Error', 'text/html'
end

-- After a Vera restart, this allows time for everything to settle down before we start polling.
-- This is a time out target; function needs to be global
function sonyBraviaStartUpDelay()
    debug('Doing the delayed start up')
    monitorSonyBravia()
end

-- Function must be global
function luaStartUp(lul_device)
    THIS_LUL_DEVICE = lul_device
    debug('Initialising plugin: '..PLUGIN_NAME)
    debug('Using: '.._VERSION)   -- returns the string: 'Lua x.y'

    -- set up some defaults:
    updateVariable('PluginVersion', PLUGIN_VERSION)

    local debugEnabled = luup.variable_get(PLUGIN_SID, 'DebugEnabled', THIS_LUL_DEVICE)
    if ((debugEnabled == nil) or (debugEnabled == '')) then
        debugEnabled = '0'
        updateVariable('DebugEnabled', debugEnabled)
    end
    DEBUG_MODE = (debugEnabled == '1')

    m_json = loadJsonModule()
    if (not m_json) then return false, 'No JSON module found', PLUGIN_NAME end

    m_connected = false
    updateVariable('Connected', '0')

    m_displayIsOn = false
    updateVariable('DisplayIsOn', '0')

    local gotPSKandIP = true

    -- create any missing variables
    local mac = luup.variable_get(PLUGIN_SID, 'MAC', THIS_LUL_DEVICE)
    if (mac == nil) then updateVariable('MAC', '') end

    local psk = luup.variable_get(PLUGIN_SID, 'PSK', THIS_LUL_DEVICE)
    if (psk == nil) then gotPSKandIP = false updateVariable('PSK', '') end
    if (psk == '')  then gotPSKandIP = false end

    local ip = luup.variable_get(PLUGIN_SID, 'IP', THIS_LUL_DEVICE)
    if (ip == nil) then gotPSKandIP = false  updateVariable('IP', '')  end
    if (ip == '')  then gotPSKandIP = false end

    if (not gotPSKandIP) then return false, 'Enter IP address and or a Pre-Shared Key', PLUGIN_NAME end

    -- Some API calls require a PSK to be set up
    m_psk = psk
    debug('Using pre-shared key: '..m_psk)

    -- Get the ip address. Avoid using luup.devices[THIS_LUL_DEVICE].ip as
    -- Vera is known to fiddle with the value. We'll keep our own variable.
    local ipAddress = string.match(ip, '^(%d%d?%d?%.%d%d?%d?%.%d%d?%d?%.%d%d?%d?)')
    if ((ipAddress == nil) or (ipAddress == '')) then return false, 'Enter a valid IP address', PLUGIN_NAME end
    m_ipAddress = ipAddress
    debug('Using IP address: '..m_ipAddress)

    -- Get the mac address. Avoid using luup.devices[THIS_LUL_DEVICE].mac as
    -- Vera is known to fiddle with the value. We'll keep our own variable.
    local macAddress = mac:match('^(%x%x:%x%x:%x%x:%x%x:%x%x:%x%x)$') or mac:match('^(%x%x%-%x%x%-%x%x%-%x%x%-%x%x%-%x%x)$')
    if ((macAddress == nil) or (macAddress == '')) then macAddress = getMacAddress(m_ipAddress) end
    if ((macAddress == nil) or (macAddress == '')) then return false, 'MAC address not found', PLUGIN_NAME end
    m_macAddress = macAddress
    updateVariable('MAC', m_macAddress)
    debug('Using MAC address: '..m_macAddress)

    -- registers a handler for the plugins's web page
    luup.register_handler('requestMain', PLUGIN_URL_ID)

    -- After a Vera restart, wait a little, till things settle down.
    -- May not be necessary but here it is anyway:
    local START_UP_DELAY_SECS = 5
    luup.call_delay('sonyBraviaStartUpDelay', START_UP_DELAY_SECS)

    -- required for UI7. UI5 uses true or false for the passed parameter.
    -- UI7 uses 0 or 1 or 2 for the parameter. This works for both UI5 and UI7
    luup.set_failure(false)

    return true, 'All OK', PLUGIN_NAME
end
