# FHEM-Tado
A FHEM extension to interact with Tado cloud

The FHEM extension requires two files:
 - 98_Tado.pm
 - 98_TadoDevice.pm

The extension is build based on the two-tier module concept.
The 98_Tado.pm contains the source code to define a Tado device. The Tado device acts like a bridge and manages the communication towards the Tado cloud.
The 98_TadoDevice.pm contains the code to define the different TadoDevices. The devices do represent either a physical device represented by a serial number, a so called zone basically representing a room or the weather channel containing the weather data used by Tado to optimize the heating times.

<h2>There are still some things todo which I have not done so far:</h2>
<ul>
<li>- Parse the several date information and bring this to local time</li>
<li>- Add validation on inserted serial numbers</li>
</ul>

<h2>There are still some things todo which I have not done so far:</h2>
<ul>
    <li>- Parse the several date information and bring this to local time</li>
    <li>- Add validation on inserted serial numbers</li>
</ul>

<a name="Tado"></a>
<h3>Tado</h3>
<ul>
    <i>Tado</i> implements an interface to the Tado cloud. The plugin can be used to read and write temperature and settings from or to the Tado cloud. The communication is based on the reengineering of the protocol done by Stephen C. Phillips. See <a href="http://blog.scphillips.com/posts/2017/01/the-tado-api-v2/">his blog</a> for more details. Not all functions are implemented within this FHEM extension. By now the plugin is capable to interact with the so called zones (rooms) and the registered devices. The devices cannot be controlled directly. All interaction - like setting a temperature - must be done via the zone and not the device. This means all configuration like the registration of new devices or the assignment of a device to a room must be done using the Tado app or Tado website directly. Once the configuration is completed this plugin can be used. This device is the 'bridge device' like a HueBridge or a CUL. Per zone or device a dedicated device of type 'TadoDevice' will be created.
    <br>
    <br>
    <a name="Tadodefine"></a>
    <b>Define</b>
    <ul>
        <code>define &lt;name&gt; Tado &lt;username&gt; &lt;password&gt; &lt;interval&gt;</code>
        <br>
        <br> Example: <code>define TadoBridge Tado mail@provider.com somepassword 120</code>
        <br>
        <br> The username and password must match the username and password used on the Tado website. Please be aware that username and password are stored and send as plain text. They are visible in FHEM user interface. It is recommended to create a dedicated user account for the FHEM integration. The Tado extension needs to pull the data from the Tado website. The 'Interval' value defines how often the value is refreshed.
    </ul>
    <br>
    <b>Set</b>
    <br>
    <ul>
        <code>set &lt;name&gt; &lt;option&gt;</code>
        <br>
        <br> The <i>set</i> command just offers very limited options. If can be used to control the refresh mechanism. The plugin only evaluates the command. Any additional information is ignored.
        <br>
        <br> Options:
        <ul>
            <li><i>interval</i>
                <br> Sets how often the values shall be refreshed. This setting overwrites the value set during define.</li>
            <li><i>start</i>
                <br> (Re)starts the automatic refresh. Refresh is autostarted on define but can be stopped using stop command. Using the start command FHEM will start polling again.</li>
            <li><i>stop</i>
                <br> Stops the automatic polling used to refresh all values.</li>
            <li><i>presence</i>
                <br> Sets the presence value for the whole Tado account. You can set the status to HOME or AWAY and depending on the status all devices will chnange their confiration between home and away mode. If you're using the mobile devices and the Tado premium feature using geofencing to determine home and away status you should not use this function.</li>
        </ul>
    </ul>
    <br>
    <a name="Tadoget"></a>
    <b>Get</b>
    <br>
    <ul>
        <code>get &lt;name&gt; &lt;option&gt;</code>
        <br>
        <br> You can <i>get</i> the major information from the Tado cloud.
        <br>
        <br> Options:
        <ul>
            <li><i>home</i>
                <br> Gets the home identifier from Tado cloud. The home identifier is required for all further actions towards the Tado cloud. Currently the FHEM extension only supports a single home. If you have more than one home only the first home is loaded.
                <br/><b>This function is automatically executed once when a new Tado device is defined.</b></li>
            <li><i>zones</i>
                <br> Every zone in the Tado cloud represents a room. This command gets all zones defined for the current home. Per zone a new FHEM device is created. The device can be used to display and overwrite the current temperatures. This command can always be executed to update the list of defined zones. It will not touch any existing zone but add new zones added since last update.
                <br/><b>This function is automatically executed once when a new Tado device is defined.</b></li>
            <li><i>update</i>
                <br/> Updates the values of:
                <br/>
                <ul>
                    <li>All Tado zones</li>
                    <li>The presence status of the whole tado account</li>
                    <li>All mobile devices - if attribute <i>generateMobileDevices</i> is set to true</li>
                    <li>All devices - if attribute <i>generateDevices</i> is set to true</li>
                    <li>The weather device - if attribute <i>generateWeather</i> is set to true</li>
                </ul>
                This command triggers a single update not a continuous refresh of the values.
            </li>
            <li><i>devices</i>
                <br/> Fetches all devices from Tado cloud and creates one TadoDevice instance per fetched device. This command will only be executed if the attribute <i>generateDevices</i> is set to <i>yes</i>. If the attribute is set to <i>no</i> or not existing an error message will be displayed and no communication towards Tado will be done. This command can always be executed to update the list of defined devices. It will not touch existing devices but add new ones. Devices will not be updated automatically as there are no values continuously changing.
            </li>
            <li><i>mobile_devices</i>
                <br/> Fetches all defined mobile devices from Tado cloud and creates one TadoDevice instance per mobile device. This command will only be executed if the attribute <i>generateMobileDevices</i> is set to <i>yes</i>. If the attribute is set to <i>no</i> or not existing an error message will be displayed and no communication towards Tado will be done. This command can always be executed to update the list of defined mobile devices. It will not touch existing devices but add new ones.
            </li>
            <li><i>weather</i>
                <br/> Creates or updates an additional device for the data bridge containing the weather data provided by Tado. This command will only be executed if the attribute <i>generateWeather</i> is set to <i>yes</i>. If the attribute is set to <i>no</i> or not existing an error message will be displayed and no communication towards Tado will be done.
            </li>
        </ul>
    </ul>
    <br>
    <a name="Tadoattr"></a>
    <b>Attributes</b>
    <ul>
        <code>attr &lt;name&gt; &lt;attribute&gt; &lt;value&gt;</code>
        <br>
        <br> You can change the behaviour of the Tado Device.
        <br>
        <br> Attributes:
        <ul>
            <li><i>generateDevices</i>
                <br> By default the devices are not fetched and displayed in FHEM as they don't offer much functionality. The functionality is handled by the zones not by the devices. But the devices offers an identification function <i>sayHi</i> to show a message on the specific display. If this function is required the Devices can be generated. Therefor the attribute <i>generateDevices</i> must be set to <i>yes</i>
                <br/><b>If this attribute is set to <i>no</i> or if the attribute is not existing no devices will be generated..</b>
            </li>
            <li><i>generateMobileDevices</i>
                <br> By default the mobile devices are not fetched and displayed in FHEM as most users already have a person home recognition. If Tado shall be used to identify if a mobile device is at home this can be done using the mobile devices. In this case the mobile devices can be generated. Therefor the attribute <i>generateMobileDevices</i> must be set to <i>yes</i>
                <br/><b>If this attribute is set to <i>no</i> or if the attribute is not existing no mobile devices will be generated..</b>
            </li>
            <li><i>generateWeather</i>
                <br> By default no weather channel is generated. If you want to use the weather as it is defined by the tado system for your specific environment you must set this attribute. If the attribute <i>generateWeather</i> is set to <i>yes</i> an additional weather channel can be generated.
                <br/><b>If this attribute is set to <i>no</i> or if the attribute is not existing no Devices will be generated..</b>
            </li>
        </ul>

    </ul>

    <br>
    <a name="Tadoreadings"></a>
    <b>Generated Readings/Events:</b>

    <ul>
        <ul>
            <li><b>DeviceCount</b>
                <br> Indicates how many devices (hardware devices provided by Tado) are registered in the linked Tado Account.
                <br/> This reading will only be available / updated if the attribute <i>generateDevices</i> is set to <i>yes</i>.
            </li>

            <li><b>LastUpdate_Devices</b>
                <br> Indicates when the last successful request to update the hardware devices (TadoDevices) was send to the Tado API. his reading will only be available / updated if the attribute <i>generateDevices</i> is set to <i>yes</i>.
            </li>

            <li><b>HomeID</b>
                <br> Unique identifier for your Tado account instance. All devices are linked to your homeID and the homeID required for almost all Tado API requests.
            </li>

            <li><b>HomeName</b>
                <br> Name of your Tado home as you have configured it in your Tado account.
            </li>

            <li><b>Presence</b>
                <br> The current presence status of your home. The status can be HOME or AWAY and is valid for the whole home and all devices and zones linked to this home. The Presence reading can be influences by the <i>set presence</i> command or based on geofencing using mobile devices.
            </li>

            <li><b>airComfort_freshness</b>
                <br> The overall fresh air indicator for your home. Represents a summary of the single indicators per zone / room.
            </li>

            <li><b>airComfort_lastWindowOpen</b>
                <br> Inidcates the last time an open window was detected by Tado to refresh the air within the home.
            </li>

            <li><b>LastUpdate_AirComfort</b>
                <br> Indicates when the last successful request to update the air comfort was send to the Tado API.
            </li>

            <li><b>LastUpdate_MobileDevices</b>
                <br> Indicates when the last successful request to update the mobile devices was send to the Tado API. his reading will only be available / updated if the attribute <i>generateMobileDevices</i> is set to <i>yes</i>.
            </li>

            <li><b>LastUpdate_Weather</b>
                <br> Indicates when the last successful request to update the weather was send to the Tado API. his reading will only be available / updated if the attribute <i>generateWeather</i> is set to <i>yes</i>.
            </li>

            <li><b>LastUpdate_Zones</b>
                <br> Indicates when the last successful request to update the zone / room data was send to the Tado API.
            </li>
        </ul>
    </ul>

</ul>

<a name="TadoDevice"></a>
<h3>TadoDevice</h3>
<ul>
    <i>TadoDevice</i> is the implementation of a zone, a device, a mobile device or the weather channel connected to one Tado instance and therefor one tado cloud account. It can only be used in conjunction with a Tado instance (a Tado bridge). The TadoDevice is intended to display the current measurements of a zone or device and allow the interaction. It can be used to set or reset the temperature within a zone or to display a "hi" statement on a physical Tado device. It can also be used to identify which mobile devices are at home. TadoDevices should not be created manually. They are auto generated once a Tado device is defined.
    <br>
    <br>
    <a name="TadoDevicedefine"></a>
    <b>Define</b>
    <ul>
        <code>define &lt;name&gt; TadoDevice &lt;TadoId&gt; &lt;IODev=IODeviceId&gt;</code>
        <br>
        <br> Example: <code>define kitchen TadoDevice 1 IODev=TadoBridge</code>
        <br>
        <br> Normally the define statement should be called by the Tado device. If called manually the TadoId and the IO-Device must be provided. The TadoId is either the zone Id if a zone shall be created or the serial number of a physical device. The IO-Device must be of type Tado.
    </ul>
    <br>
    <a name="TadoDeviceset"></a>
    <b>Set</b>
    <br>
    <ul>
        <code>set &lt;name&gt; &lt;option&gt; &lt;value&gt;</code>
        <br>
        <br> What can be done with the <i>set</i> command is depending on the subtype of the TadoDevice. For all thermostats it is possible to set the temperature using the automatic, temperature and temperature-for options. For all physical devices the sayHi option is available.
        <br>
        <br> Options:
        <ul>
            <li><i>sayHi</i>
                <br>
                <b>Works on devices only.</b> Sends a request to the a specific physical device. Once the request reaches the device the device displays "HI". Command can be used to identify a physical device.
            </li>
            <li><i>automatic</i>
                <br>
                <b>Works on zones only.</b> Resets all temperature settings for a zone. The plan defined in the cloud (either by app or browser) will be used to set the temperature</li>
            <li><i>off</i>
                <br>
                <b>Works on zones only.</b> Turns the heating in the specific zone completely off. The setting will be kept until a new temperature is defined via app, browser or FHEM.
                <li><i>temperature</i>
                    <br>
                    <b>Works on zones only.</b> Sets the temperature for a zone. The setting will be kept until a new temperature is defined via app, browser or FHEM. Value can be <i>off</i> or any numeric value between 4.0 and 25.0 with a precision of 0.1 degree.
                    <li><i>temperature-for-60</i>
                        <br>
                        <b>Works on zones only.</b> Sets the temperature for a zone for 60 minutes only. The temperature will be kept for 60 minutes. Afterwards the zone will fall back to the standard plan defined in app or web. Value definition is like for command <i>set temperature</i>.</li>
                    <li><i>temperature-for-90</i>
                        <br>
                        <b>Works on zones only.</b> Sets the temperature for a zone for 90 minutes only. The temperature will be kept for 90 minutes. Afterwards the zone will fall back to the standard plan defined in app or web. Value definition is like for command <i>set temperature</i>.</li>
                    <li><i>temperature-for-120</i>
                        <br>
                        <b>Works on zones only.</b> Sets the temperature for a zone for 120 minutes only. The temperature will be kept for 120 minutes. Afterwards the zone will fall back to the standard plan defined in app or web. Value definition is like for command <i>set temperature</i>.</li>
                    <li><i>temperature-for-180</i>
                        <br>
                        <b>Works on zones only.</b> Sets the temperature for a zone for 180 minutes only. The temperature will be kept for 180 minutes. Afterwards the zone will fall back to the standard plan defined in app or web. Value definition is like for command <i>set temperature</i>.</li>
                    <li><i>temperature-for-240</i>
                        <br>
                        <b>Works on zones only.</b> Sets the temperature for a zone for 240 minutes only. The temperature will be kept for 240 minutes. Afterwards the zone will fall back to the standard plan defined in app or web. Value definition is like for command <i>set temperature</i>.</li>
                    <li><i>temperature-for-300</i>
                        <br>
                        <b>Works on zones only.</b> Sets the temperature for a zone for 300 minutes only. The temperature will be kept for 300 minutes. Afterwards the zone will fall back to the standard plan defined in app or web. Value definition is like for command <i>set temperature</i>.</li>
        </ul>
    </ul>
    <br>
    <a name="TadoDeviceget"></a>
    <b>Get</b>
    <br>
    <ul>
        <code>get &lt;name&gt; &lt;option&gt;</code>
        <br>
        <br> The only available <i>get</i> function is called <b>update</b> and can be used to update all readings of the specific TadoDevice.
        <br>
        <br> Options:
        <ul>
            <li><i>Update</i>
                <br>
                <b>This <i>get</i> command is available on zones, weather and mobile devices</b> This call updates the readings of a <i>TadoDevie</i> with the latest values available in the Tado cloud.
            </li>
        </ul>
    </ul>
    <br>
    <a name="TadoDeviceattr"></a>
    <b>Attributes</b>
    <ul>
        <code>attr &lt;name&gt; &lt;attribute&gt; &lt;value&gt;</code>
        <br>
        <br> There is one attribute available. It only affects zones.
        <br>
        <br> Attributes:
        <ul>
            <li><i>earlyStart</i> true|false
                <br> When set to true the Tado system starts to heat up before the set heating change. The intention is to reach the target temperature right at the point in time defined. E.g. if you want to change the temperature from 20 degree to 22 degree on 6pm early start would start heating at 5:30pm so the zone is on 22 degree at 6pm. The early start is a feature of Tado. How this is calculated and how early the heating is started is up to Tado.
            </li>
        </ul>
    </ul>
    <br>
    <br>
    <a name="TadoDevicereadings"></a>
    <b>Generated Readings/Events for subtype <i>zone</i>:</b>
    <br>
    <br>
    <ul>
        <li><b>Basic readings</b>
            <br> Contains a list of the basic readings beeing available all the time. This is mainly the status of the room, the actual measured values and the desired values.</li>
        <br>
        <ul>
            <li><b>date_created</b>
                <br> Indicates when this zone was created within the Tado account (not within FHEM).
            </li>
            <li><b>link</b>
                <br> Indicates if the Tado hardware in the specific zone is currently ONLINE or OFFLINE.
            </li>
            <li><b>tado-mode</b>
                <br> Indicates if the heating parameters applied to the specific zone are based on the <i>HOME</> or the <i>AWAY</i> configuration.
            </li>
            <li><b>desired-temp</b>
                <br> The desired room or water temperature.
            </li>
            <li><b>measured-temp</b>
                <br> The temperature measured by the Tado device in the specific zone / room in °C
            </li>
            <li><b>measured-temp-fahrenheit</b>
                <br> The temperature measured by the Tado device in the specific zone / room in °F
            </li>
            <li><b>measured-temp-precision</b>
                <br> Indicates the precision of the data beeing provided in <i>measured-temp</i> reading.
            </li>
            <li><b>measured-temp-precision-fahrenheit</b>
                <br> Indicates the precision of the data beeing provided in <i>measured-temp-fahrenheit</i> reading.
            </li>
            <li><b>measured-temp-timestamp</b>
                <br> Indicates when the values in <i>measured-temp</i> and <i>measured-temp-fahrenheit</i> were actually measured.
                <br> If the connection between the Tado bridge and the Tado webserver is broken values may get aged. This can be identified using this reading.
            </li>
            <li><b>measured-humidity</b>
                <br> The humidity measured by the Tado device in the specific zone / room in %
            </li>
            <li><b>measured-humidity-timestamp</b>
                <br> Indicates when the value in <i>measured-humidity</i> was actually measured.
                <br> If the connection between the Tado bridge and the Tado webserver is broken values may get aged. This can be identified using this reading.
            </li>
            <li><b>heating-percentage</b>
                <br> If your heating is capable to run in a more fine grained operation mode than purly ON and OFF and Tado is capable to control the heating on this level, the current heating level in percent is contained in this reading.
                <br> Example: If you do have a floor heating the heating temperature is controlled by a valve which can be opened in 10% steps. In this case this reading contains valid values.
            </li>
            <li><b>heating-percentage-timestamp</b>
                <br> Indicates when the value in <i>heating-percentage</i> was actually measured.
                <br> If the connection between the Tado bridge and the Tado webserver is broken values may get aged. This can be identified using this reading.
            </li>

            <li><b>open-window</b>
                <br> If tado recognizes an open window within the current zone / room this reading contains the timestamp since when the window is open. If no open window is detected the reading contains the value <i>null</i>
            </li>

            <li><b>supportsDazzle</b>
                <br> Tado dazzle mode shows status changes made via web or mobile app on the Tado device. E.g. if you change the temperature in a zone / room via app, the Tado device displays the new temperature for some seconds so you can check you chnaged the correct device. This reading indicates if the current zone / room and the devices within support dazzle mode.
            </li>

        </ul>
        <br>
        <li><b>Scheduled Changes</b>
            <br> Tado supports so called <i>intelligent schedules</i>. Within an intelligent schedule certain timeframes are defined and within the timeframes the desired temperature is set. As the intelligent part of the feature Tado documents previous heating cycles and knows the time it takes to heat up. So Tado starts heating before the scheduled date so the room is already at desired temperature when the schedule changes. A zone / room can have different intelligent schedules depending on the <i>tado-mode</i> HOME and AWAY.
        </li>
        <br>
        <ul>

            <li><b>nextScheduleChange-start</b>
                <br> This reading indicates when the next interval of the schedule will begin.
            </li>
            <li><b>nextScheduleChange-power</b>
                <br> This reading indicates weather the zone will be powered or not on the next change. This could be a heating turned on or a warm water boiler turned to heating mode.
            </li>
            <li><b>nextScheduleChange-temperature</b>
                <br> This reading indicates the desired temperature for the next scheduled change.
            </li>

        </ul>
        <br>
        <li><b>Overlay - Manual temperature adjustments</b>
            <br> If you manually adjust the temperature for a zone / room either using the Tado device or the Tado app this is calles an override. An override can be temporary and will end after a certain time periode or it is infinite and stays active until it is ended by the user.
        </li>
        <br>
        <ul>

            <li><b>overlay-active</b>
                <br> This reading indicates if such an override is active (<i>1</i>) or inactive (<i>0</i>).
            </li>
            <li><b>overlay-desired-temperature</b>
                <br> This reading indicates the desired temperature while the overlay is active.
            </li>
            <li><b>overlay-mode</b>
                <br> This reading indicates the mode of the overlay.
            </li>
            <li><b>overlay-power</b>
                <br> This reading indicates if the heating, boiler or AC is turned on while the overlay is active.
            </li>
            <li><b>overlay-termination-mode</b>
                <br> This reading indicates the termination mode currently active.
                <i>MANUAL</i> indicates the current mode will be active until it is changed by the user and <i>TIMER</i> means it automatically gets disabled once the timer is expired.
            </li>
            <li><b>overlay-termination-durationInSeconds</b>
                <br> This reading indicates how long the overlay will be active in seconds.
            </li>
            <li><b>overlay-termination-expiry</b>
                <br> This reading indicates the date and time when the overlay will expire and Tado will return to automatic operation.
            </li>
            <li><b>overlay-termination-remainingTimeInSeconds</b>
                <br> This reading indicates the remaining time in seconds until the zone / room will be turned back to automatic operation.
            </li>

        </ul>
        <br>
        <li><b>Overlay - Manual temperature adjustments</b>
            <br> The measured humidity and temperature in a room are evaluated and an air comfort is calculated. The air comfort is provided in english, human readable words for humidity and temperature and by a radar chart visualizing the air comfort. The graph is displayed in the Tado app but cannnot be displayed in FHEM. But you can use the angular and radial values to create your own radar chart.
        </li>
        <br>
        <ul>

            <li><b>airComfort_humidityLevel</b>
                <br> An english, human readable expression defining the air comfort of your current humidity level.
            </li>
            <li><b>airComfort_temperatureLevel</b>
                <br> An english, human readable expression defining the air comfort of your current temperature level.
            </li>
            <li><b>airComfort_graph_angular</b>
                <br> A radar chart has an angular and a radial axis. This reading contains the numeric value for the angular axis.
            </li>
            <li><b>airComfort_graph_radial</b>
                <br> A radar chart has an angular and a radial axis. This reading contains the numeric value for the radial axis.
            </li>
        </ul>
    </ul>

    <br>
    <br>

    <b>Generated Readings/Events for subtype <i>thermostat</i> and <i>bridge</i>:</b>
    <br>
    <br>
    <ul>
        <ul>
            <li><b>batteryState</b>
                <br> The state of the battery for the Tado hardware device.
            </li>
            <li><b>connectionState</b>
                <br> The current connection state.
            </li>
            <li><b>connectionStateLastUpdate</b>
                <br> Date and time when the current connection state was registered in the Tado cloud application.
            </li>
            <li><b>currentFwVersion</b>
                <br> The firmware version of the Tado hardware.
            </li>
            <li><b>inPairingMode</b>
                <br> Indicates if a Tado bridge device is in pairing mode and accepts new Tado devices.
            </li>
        </ul>
    </ul>

    <br>
    <br>

    <b>Generated Readings/Events for subtype <i>mobile_device</i>:</b>
    <br>
    <br>
    <ul>
        <ul>
            <li><b>device_locale</b>
                <br> The languange settings for the device.
            </li>
            <li><b>device_model</b>
                <br> The model or make of the device.
            </li>
            <li><b>device_os_version</b>
                <br> The operating system version of the device.
            </li>
            <li><b>device_platform</b>
                <br> The software platform of the device.
            </li>
            <li><b>geoTrackingEnabled</b>
                <br> Indicates if geofencing is enabled for the device. If geofencing is enabled Tado can switch between the presence modes of HOME and AWAY. To automatically switch you do need a paid premium plan. Otherwise you get a push notification on your mobile and can invoke a status change.
            </li>
            <li><b>pushNotification_LowBatteryReminder</b>
                <br> Indicates if the device will get a push notification if the battery of a Tado device is running low.
            </li>
            <li><b>pushNotification_awayModeReminder</b>
                <br> Indicates if the device will get a push notification if the geofencing detects leaving a fenced area and offers to swicth to AWAY mode.
            </li>
            <li><b>pushNotification_homeModeReminder</b>
                <br> Indicates if the device will get a push notification if the geofencing detects entering a fenced area and offers to swicth to HOME mode.
            </li>
            <li><b>pushNotification_energySavingsReportReminder</b>
                <br> Indicates if the device will get a push notification once a new energy saving report is available in Tado Cloud.
            </li>
            <li><b>pushNotification_openWindowReminder</b>
                <br> Indicates if the device will get a push notification if an open window was detected and offers to temporary turn of the heating.
            </li>
        </ul>
    </ul>

    <br>
    <br>

    <b>Generated Readings/Events for subtype <i>weather</i>:</b>
    <br>
    <br>
    <ul>
        <li>The Tado weather is not measured using your local devices. Tado is using weather data from a service provider and the address you configured when creating your Tado account to estimate your local weather. There may be internet data of local weather stations or your own weather station providing much more accurate data.
        </li>
        <ul>
            <li><b>outsideTemperature</b>
                <br> The current outside temperature.
            </li>
            <li><b>outsideTemperature-timestamp</b>
                <br> The timestamp when current outside temperature was updated.
            </li>
            <li><b>solarIntensity</b>
                <br> The current solar intensity - the relative brightness of the sub in %
            </li>
            <li><b>solarIntensity-timestamp</b>
                <br> The timestamp when current solar intensity was updated.
            </li>
            <li><b>weatherState</b>
                <br> An english, human readable text describing the current weather conditions.
            </li>
            <li><b>weatherState-timestamp</b>
                <br> The timestamp when current weather state was updated.
            </li>
        </ul>
    </ul>

</ul>
