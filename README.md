# FHEM-Tado
A FHEM extension to interact with Tado cloud

The FHEM extension requires two files:
 - 98_Tado.pm
 - 98_TadoDevice.pm
 
The extension is build based on the two-tier module concept.
The 98_Tado.pm contains the source code to define a Tado device. The Tado device acts like a bridge and manages the communication towards the Tado cloud.
The 98_TadoDevice.pm contains the code to define the different TadoDevices. The devices do represent either a physical device represented by a serial number, a so called zone basically representing a room or the weather channel containing the weather data used by Tado to optimize the heating times.



#Tado
Tado implements an interface to the Tado cloud. The plugin can be used to read and write temperature and settings from or to the Tado cloud. The communication is based on the reengineering of the protocol done by Stephen C. Phillips. See his blog for more details. Not all functions are implemented within this FHEM extension. By now the plugin is capable to interact with the so called zones (rooms) and the registered devices. The devices cannot be controlled directly. All interaction - like setting a temperature - must be done via the zone and not the device. This means all configuration like the registration of new devices or the assignment of a device to a room must be done using the Tado app or Tado website directly. Once the configuration is completed this plugin can be used. This device is the 'bridge device' like a HueBridge or a CUL. Per zone or device a dedicated device of type 'TadoDevice' will be created. 

Define
define <name> Tado <username> <password> <interval> 

Example: define TadoBridge Tado mail@provider.com somepassword 120 

The username and password must match the username and password used on the Tado website. Please be aware that username and password are stored and send as plain text. They are visible in FHEM user interface. It is recommended to create a dedicated user account for the FHEM integration. The Tado extension needs to pull the data from the Tado website. The 'Interval' value defines how often the value is refreshed.

Set
set <name> <option> 

The set command just offers very limited options. If can be used to control the refresh mechanism. The plugin only evaluates the command. Any additional information is ignored. 

Options:
interval
Sets how often the values shall be refreshed. This setting overwrites the value set during define.
start
(Re)starts the automatic refresh. Refresh is autostarted on define but can be stopped using stop command. Using the start command FHEM will start polling again.
stop
Stops the automatic polling used to refresh all values.

Get
get <name> <option> 

You can get the major information from the Tado cloud. 

Options:
home
Gets the home identifier from Tado cloud. The home identifier is required for all further actions towards the Tado cloud. Currently the FHEM extension only supports a single home. If you have more than one home only the first home is loaded. 
This function is automatically executed once when a new Tado device is defined.
zones
Every zone in the Tado cloud represents a room. This command gets all zones defined for the current home. Per zone a new FHEM device is created. The device can be used to display and overwrite the current temperatures. This command can always be executed to update the list of defined zones. It will not touch any existing zone but add new zones added since last update. 
This function is automatically executed once when a new Tado device is defined.
devices
Fetches all devices from Tado cloud and creates one TadoDevice instance per fetched device. This command can always be executed to update the list of defined devices. It will not touch existing devices but add new ones.
update
Updates the values of all Tado zones - not the tado devices.

Attributes
attr <name> <attribute> <value> 

No attributes so far...




#TadoDevice
TadoDevice is the implementation of a zone, a device or the weather channel related to a tado cloud account. It can only be used in conjunction with a Tado device (a Tado bridge). The TadoDevice is intended to display the current measurements of a zone or device and allow the interaction. It can be used to set or reset the temperature within a zone or to display a "hi" statement on a physical Tado device. TadoDevices should not be created manually. They are auto generated once a Tado device is defined. 

Define
define <name> TadoDevice <TadoId> <IODev=IODeviceId> 

Example: define kitchen TadoDevice 1 IODev=TadoBridge 

Normally the define statement should be called by the Tado device. If called manually the TadoId and the IO-Device must be provided. The TadoId is either the zone Id if a zone shall be created or the serial number of a physical device. The IO-Device must be of type Tado.

Set
set <name> <option> <value> 

What can be done with the set command is depending on the subtype of the TadoDevice. For all thermostats it is possible to set the temperature using the automatic, temperature and temperature-for options. For all physical devices the sayHi option is available. 

Options:
sayHi
Sends a request to the a specific physical device. Once the request reaches the device the device displays "HI". Command can be used to identify a physical device.
automatic
Resets all temperature settings for a zone. The plan defined in the cloud (either by app or browser) will be used to set the temperature
temperature-for-60
Sets the temperature for a zone for 60 minutes only. The temperature will be kept for 60 minutes. Afterwards the zone will fall back to the standard plan defined in app or web.
temperature-for-90
Sets the temperature for a zone for 90 minutes only. The temperature will be kept for 90 minutes. Afterwards the zone will fall back to the standard plan defined in app or web.
temperature-for-120
Sets the temperature for a zone for 120 minutes only. The temperature will be kept for 120 minutes. Afterwards the zone will fall back to the standard plan defined in app or web.
temperature-for-180
Sets the temperature for a zone for 180 minutes only. The temperature will be kept for 180 minutes. Afterwards the zone will fall back to the standard plan defined in app or web.
temperature-for-240
Sets the temperature for a zone for 240 minutes only. The temperature will be kept for 240 minutes. Afterwards the zone will fall back to the standard plan defined in app or web.
temperature-for-300
Sets the temperature for a zone for 300 minutes only. The temperature will be kept for 300 minutes. Afterwards the zone will fall back to the standard plan defined in app or web.

Get
get <name> <option> 

The only available get function is called update and can be used to update all readings of the specific TadoDevice.

Attributes
attr <name> <attribute> <value> 

There is one attribute available. It only affects zones. 

Attributes:
earlyStart true|false
When set to true the Tado system starts to heat up before the set heating change. The intention is to reach the target temperature right at the point in time defined. E.g. if you want to change the temperature from 20 degree to 22 degree on 6pm early start would start heating at 5:30pm so the zone is on 22 degree at 6pm. The early start is a feature of Tado. How this is calculated and how early the heating is started is up to Tado.
