print('WifiSwitcher start.')

local sw = {

	state = {
		INIT 		= 0,
		CONFIG 		= 1,
		CONNECTTING = 2,
		WORK 		= 3,
		ERROR 		= 4,
	},

	config = {
		--Hardware
		ledPin 	= 0,
		swPin	= 1,

		--Software
		-- 0:init 1:config 2:connecting 3:work 4:error
		Mode 	= 0, 
		SSID 	= "",
		PASS 	= "",
		IP 		= "",
		tcpPort = 80,
		udpPort = 1900, --SSDP
	},

	try = 1,
	ledTimerId = 2,
	checkTimerId = 3,
	udpServer = nil,
	tcpServer = nil,
};

function initWifiSwitcher()

	gpio.mode(sw.config.ledPin, gpio.OUTPUT)
	gpio.mode(sw.config.swPin, gpio.OUTPUT)
	gpio.write(sw.config.ledPin, gpio.LOW)
	gpio.write(sw.config.swPin, gpio.HIGH)

	sw.config.Mode = sw.state.INIT
	collectgarbage()
end	

function getSettings(filename)

	if file.open(filename, "r")  == nil then
		return false
	end

	local line = file.readline()
	while line do
		local key, value = string.match(line, "%s*(%w+)%s*=%s*([^%s%c\r\n]+)%s*%c*")
		if key == "SSID" then
			sw.config.SSID = value;
		elseif key == "PASS" then
			sw.config.PASS = value;
		end
		line = file.read()
	end
	file.close()

	if sw.config.SSID ~= "" and sw.config.PASS ~= "" then
		return true
	end

	return false
end

function saveSettings(filename)

	if sw.config.SSID == nil or sw.config.PASS == nil then
		return false
	end

	if file.open(filename, "w+") then
		file.writeline("SSID = " .. sw.config.SSID)
		file.writeline("PASS = " .. sw.config.PASS)
		file.close()
		return true
	end

	return false
end

function operaterSwitcher(op)
	--[[
		The SWITCHER is lOW LEVEL triger
		logic   switcher  pin
		ON      OFF       HIGH
		OFF     ON        LOW
	--]]
	
	local stat = "ON"

	--Login ON
	if op == "on" then
		gpio.write(sw.config.swPin, gpio.HIGH)
		blinkLED(1000) -- NORMAL
	elseif op == "stat" then
		if gpio.read(sw.config.swPin) == gpio.LOW then
			stat = "OFF"
		end
	else 
		gpio.write(sw.config.swPin, gpio.LOW)
		blinkLED(3000)
	end
	
	return stat
end

function blinkLED(interval)
	tmr.alarm(sw.ledTimerId, interval, tmr.ALARM_AUTO, 
	function()
		local pin = sw.config.ledPin
		local v = {gpio.HIGH, gpio.LOW}
		gpio.mode(pin, gpio.OUTPUT)
		gpio.write(pin, v[gpio.read(pin)+1])
	end)
end

function startUdpService()

	if sw.udpServer ~= nil then
		sw.udpServer:close()
		sw.udpServer = nil
	end

	sw.udpServer = net.createServer(net.UDP)
	if sw.udpServer ~= nil then
		print("SSDPServer is running @" .. sw.config.IP .. ":" .. sw.config.udpPort)
	end

	if sw.udpServer then
		sw.udpServer:listen(sw.config.udpPort)
		sw.udpServer:on("receive", 
		function(sck ,data) 
			if data == "check" or data ==  "check\r\n" or data == "check\n" then
				sck.send(sck, sw.config.IP .. ":" .. sw.config.tcpPort)
			end
		end)
	end
end

function startTcpService()

	if sw.tcpServer ~= nil then
		sw.tcpServer:close()
		sw.tcpServer = nil
	end

	sw.tcpServer = net.createServer(net.TCP, 30)
	if sw.tcpServer ~= nil then
		print("HTTPServer is running @" .. sw.config.IP .. ":" .. sw.config.tcpPort)
	end

	if sw.tcpServer then
		sw.tcpServer:listen(sw.config.tcpPort, function(conn)
			conn:on("receive", tcp_receiver_handler)
		end)
	end

end

function tcp_receiver_handler(sck, data)

	local pin = sw.config.swPin
	local response = ""

	if string.find(data, "/op%?cmd=turnon") then
		operaterSwitcher("on")
		response = "switcher is turn on"

	elseif string.find(data, "/op%?cmd=turnoff") then
		operaterSwitcher("off")
		response = "switcher is turn off"

	elseif string.find(data, "/op%?cmd=status") then
		local stat = operaterSwitcher("stat")
		response = string.format("<html>SSID:%s<br>IP:%s<br>status:%s</br><html>", 
		sw.config.SSID, sw.config.IP, stat)

	elseif string.find(data, "/op%?cmd=help") then
		local turl = sw.config.IP .. ":" .. sw.config.tcpPort
		local uurl = sw.config.IP .. ":" .. sw.config.udpPort
		response = string.format("<html>TurnOn\t:http://%s/op?cmd=turnon<br>\
		TurnOff\t:http://%s/op?cmd=turnoff<br>\
		Status\t:http://%s/op?cmd=status<br>\
		Setup\t:http://%s/setup?SSID=xxxx&PASS=xxxxxxxx<br>\
		SSDP\t:udp:%s<br><html>",
		turl, turl, turl, turl, uurl)
	
		-- EXAMPLE : GET /setup?SSID=test&PASS=123 HTTP/1.1
	elseif string.find(data, "/setup%?") then
		local ssidv = nil
		local passv = nil
		local str = string.match(data, "/setup%?([%w\&\*\?=]+)%s*HTTP")

		if str then
			print(str)
			ssidv = string.match(str, "SSID=([%w]+)")
			passv = string.match(str, "PASS=([%w\?\*\#]+)")
		end

		if ssidv == nil or passv == nil then
			response = "invalid param" 
			sck.send(sck, response)
			sck:close()
			return
		end		

		if (string.len(passv) < 8 or string.len(ssidv) < 1) then
			response = "invalid param" 
			sck.send(sck, response)
			sck:close()
			return
		end		

		sw.config.SSID = ssidv
		sw.config.PASS = passv

		--print(sw.config.SSID, sw.config.PASS)
		saveSettings("sw.ini")

		response = "Settings OK. Try to connect to WiFi." 
		sck.send(sck, response)
		sck:close()

		switchToMode(sw.state.CONNECTTING)
		return
	end

	sck.send(sck, response)
	sck:close()
end


function beginConfigMode()

	sw.config.Mode = sw.state.CONFIG
	wifi.setmode(wifi.SOFTAP)

	ap_cfg={}
	ap_cfg.ssid="WifiSwitcher"
	ap_cfg.pwd="12345678"
	wifi.ap.config(ap_cfg)

	dhcp_config ={}
	dhcp_config.start = "192.168.1.100"
	wifi.ap.dhcp.config(dhcp_config)
	wifi.ap.dhcp.start()

	ip_cfg = {}
	ip_cfg.ip="192.168.1.1"
	ip_cfg.netmask="255.255.255.0"
	ip_cfg.gateway="192.168.1.1"
	wifi.ap.setip(ip_cfg)
	sw.config.IP = wifi.ap.getip()

	startTcpService()

	blinkLED(500)
end

function beginConnectMode()

	blinkLED(200)

	sw.config.Mode = sw.state.CONNECTTING
	wifi.setmode(wifi.STATION)
	wifi.sta.autoconnect(0)
	wifi.sta.config(sw.config.SSID, sw.config.PASS)
	wifi.sta.connect()
	print("Try to connect to WiFi(" .. sw.config.SSID .. ") ...")

	tmr.alarm(sw.checkTimerId, 3000, tmr.ALARM_SEMI, 
	function()

		local scode = wifi.sta.status()	

		if scode == 1 then
			-- wait for got IP
			tmr.start(sw.checkTimerId)
		end

		-- STATION_WRONG_PASSWORD
		if scode == 2 then
			print("WiFi connect failed(STATION_WRONG_PASSWORD).")
			tmr.stop(sw.checkTimerId)
			switchToMode(sw.state.CONFIG)
			return
		end

		-- STATION_NO_AP_FOUND  or STATION_CONNECT_FAIL
		if scode == 3 or scode == 4 then
			print("WiFi connect failed(STATION_NO_AP_FOUND/STATION_CONNECT_FAIL).")
			if sw.try > 3 then
				tmr.stop(sw.checkTimerId)
				switchToMode(sw.state.CONFIG)
				return
			end

			sw.try = sw.try + 1
			print("Try to reconnnect (" .. sw.try .. ")time ...")
			wifi.sta.disconnect()
			wifi.sta.connect()
			tmr.start(sw.checkTimerId)
		end

		-- STATION_GOT_IP
		if scode == 5 then
			tmr.stop(sw.checkTimerId)
			sw.config.IP = wifi.sta.getip()
			switchToMode(sw.state.WORK)
		end

	end)
end

function beginWorkMode()
	sw.config.Mode = sw.state.WORK
	startTcpService()
	startUdpService()
	blinkLED(1000)
end

function switchToMode(mode)

	local msg = {"INIT", "CONFIG", "CONNECTTING", "WORK", "ERROR"}

	print("Switch to [" .. msg[mode+1] .. "] Mode ...")
	if mode == sw.state.CONFIG then
		beginConfigMode()
	elseif mode == sw.state.CONNECTTING then 
		beginConnectMode()
	elseif mode == sw.state.WORK then
		beginWorkMode()
	end
end

function main()

	initWifiSwitcher()
	
	if getSettings("sw.ini") == false then
		print("Not found sw.ini or invalid config item")
		switchToMode(sw.state.CONFIG)

	else
		switchToMode(sw.state.CONNECTTING)
	end

end

main()
