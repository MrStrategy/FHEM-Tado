package main;
use strict;
use warnings;

use strict;
use warnings;
use Data::Dumper;
use utf8;
use Encode qw( encode_utf8 );
use HttpUtils;
use JSON;

my %Tado_gets = (
	"update" => " ",
	"home"	=> " ",
	"zones"	=> " ",
	"devices"  => " ",
	"weather" => " "
);

my %Tado_sets = (
	"start"	=> " ",
	"stop" => " ",
	"interval" => " "
);

my  %url = ( "getZoneTemperature"     => 'https://my.tado.com/api/v2/homes/#HomeID#/zones/#ZoneID#/state?username=#Username#&password=#Password#',
             "setZoneTemperature"     => 'https://my.tado.com/api/v2/homes/#HomeID#/zones/#ZoneID#/overlay?username=#Username#&password=#Password#',
             "earlyStart"             => 'https://my.tado.com/api/v2/homes/#HomeID#/zones/#ZoneID#/earlyStart?username=#Username#&password=#Password#', 
             "getZoneDetails"         => 'https://my.tado.com/api/v2/homes/#HomeID#/zones?username=#Username#&password=#Password#' ,
             "getHomeId"              => 'https://my.tado.com/api/v2/me?username=#Username#&password=#Password#',
             "getHomeDetails"         =>  'https://my.tado.com/api/v2/homes/#HomeID#?username=#Username#&password=#Password#',
             "getWeather"             =>  'https://my.tado.com/api/v2/homes/#HomeID#/weather?username=#Username#&password=#Password#',
             "getDevices"             =>  'https://my.tado.com/api/v2/homes/#HomeID#/devices?username=#Username#&password=#Password#',
             "identifyDevice"		  =>  'https://my.tado.com/api/v2/devices/#DeviceId#/identify?username=#Username#&password=#Password#');
 

sub Tado_Initialize($) {
    my ($hash) = @_;

    $hash->{DefFn}      = 'Tado_Define';
    $hash->{UndefFn}    = 'Tado_Undef';
    $hash->{SetFn}      = 'Tado_Set';
    $hash->{GetFn}      = 'Tado_Get';
    $hash->{AttrFn}     = 'Tado_Attr';
    $hash->{ReadFn}     = 'Tado_Read';
    
    $hash->{WriteFn}    = 'Tado_Write';
    
    $hash->{Clients} = ":TadoDevice:";
    $hash->{MatchList} = { "1:TadoDevice"  => "^Tado;.*"};
    $hash->{AttrList} =
          "generateDevices:yes,no "
        . "generateWeather:yes,no "
        . $readingFnAttributes;
    
	Log 3, "Tado module initialized.";
	    
  }    


sub Tado_Define($$) {
  my ($hash, $def) = @_;
  my @param = split("[ \t]+", $def);
  my $name = $hash->{NAME};


  Log3 $name, 3, "Tado_Define $name: called ";

  my $errmsg = '';
  
  # Check parameter(s)
  if( int(@param) != 5 ) {
    $errmsg = return "syntax error: define <name> Tado <username> <password> [Interval]";
    Log3 $name, 1, "Tado $name: " . $errmsg;
    return $errmsg;
  }
  
  if ( $param[2] =~ /^.+@.+$/ ) {
    $hash->{Username} = $param[2];
    setKeyValue(  "Tado_".$hash->{Username}, $param[2] );
  } else {
    $errmsg = "specify valid email address within the field username. Format: define <name> Tado <username> <password> <interval>";
    Log3 $name, 1, "Tado $name: " . $errmsg;
    return $errmsg;
  }
  
    $hash->{Password} = $param[3];
    setKeyValue(  "Tado_".$hash->{Password}, $param[3] );


    my $interval = $param[4];
    $interval= 60 unless defined($interval);
    if( $interval < 5 ) { $interval = 5; }

    $hash->{INTERVAL} = $interval;
    setKeyValue(  "Tado_".$hash->{Interval}, $param[4] );


    RemoveInternalTimer($hash);

    $hash->{STATE} = "Undefined";    
  
  
  	$attr{$name}{generateDevices} = "no" if( !defined( $attr{$name}{generateDevices} ) );
  	$attr{$name}{generateWeather} = "no" if( !defined( $attr{$name}{generateWeather} ) );
  
  
    Tado_GetHomes($hash);
    
    RemoveInternalTimer($hash);
    
    #Call getZones with delay of 15 seconds, as all devices need to be loaded before timer triggers.
    #Otherwise some error messages are generated due to auto created devices...
    InternalTimer(gettimeofday()+15, "Tado_GetZones", $hash) if (defined $hash);  
    
  
    Log3 $name, 5, "Tado_Define $name: Starting timer with Interval $hash->{INTERVAL}";
    InternalTimer(gettimeofday()+$hash->{INTERVAL}, "Tado_GetUpdate", $hash) if (defined $hash);  
    
    
    return undef;
}

sub Tado_Undef($$) {
  my ($hash,$arg) = @_;

  RemoveInternalTimer($hash);
  return undef;
}

sub Tado_httpSimpleOperation($$$;$){
  my ($hash,$url, $operation, $message) = @_;
  my ($json,$err,$data,$decoded);
  my $name = $hash->{NAME};
  
  my $request = {
    url           => $url,
    header        => "Content-Type:application/json;charset=UTF-8",
    method        => $operation,
    timeout       =>  2,
    hideurl       =>  1
  };
  $request->{data} = $message if (defined $message);
  
  Log3 $name, 5, 'Request: ' . Dumper($request);
  
  ($err,$data)    = HttpUtils_BlockingGet($request);

  
  $json = "" if( !$json );
  $data = "" if( !$data );
  
  Log3 $name, 4, "FHEM -> Tado: " . $url; 
  Log3 $name, 4, "FHEM -> Tado: " . $message if (defined $message); 
  Log3 $name, 4, "Tado -> FHEM: " . $data;
  
  Log3 $name, 5, '$err: ' . $err;
  Log3 $name, 5, "method: " . $operation;
  
  Log3 $name, 3, "Something gone wrong" if( $data =~ "/tadoMode/" );
  $err = 1 if( $data =~ "/tadoMode/" );
  
  if (defined $data and $operation ne 'DELETE') {
  	$decoded  = decode_json($data) if( !$err ); 
  	Log3 $name, 5, 'Decoded: ' . Dumper($decoded);
  	return $decoded;
  } else {
    return undef;
  }
}


sub Tado_Get($@) {
    my ( $hash, $name, @args ) = @_;
 
	return '"get Tado" needs at least one argument' if (int(@args) < 1);

	my $opt = shift @args;
	if(!$Tado_gets{$opt}) {
		my @cList = keys %Tado_gets;
		return "Unknown! argument $opt, choose one of " . join(" ", @cList);
	}
	
	my $cmd = $args[0];
    my $arg = $args[1];

	
	if($opt eq "home"){
	
	   return Tado_GetHomes($hash);
	
	} elsif($opt eq "zones") {
	
	   return Tado_GetZones($hash);

	
	}  elsif($opt eq "devices") {
	
	  return Tado_GetDevices($hash);
	
	}  elsif($opt eq "update")  {
	   
		Log3 $name, 3, "Tado_Get $name: Updating readings for all zones";  
    	$hash->{LOCAL} = 1;
    	Tado_GetUpdate($hash);
    	delete $hash->{LOCAL};
       
	}  elsif($opt eq "weather")  {
	   
		Log3 $name, 3, "Tado_Get $name: Getting weather";  
    	return Tado_DefineWeatherChannel($hash);       
       
	}  else
	{
		my @cList = keys %Tado_gets;
		return "Unknown v2 argument $opt, choose one of " . join(" ", @cList);
	}
}

sub Tado_Set($@) {
	my ($hash, $name, @param) = @_;
	
	return '"set $name" needs at least one argument' if (int(@param) < 1);
	
	my $opt = shift @param;
	my $value = join("", @param);
	
	if(!defined($Tado_sets{$opt})) {
		my @cList = keys %Tado_sets;
		return "Unknown argument $opt, choose one of " . join(" ", @cList);
	}
   
	if ($opt eq "start")	{
	
	
	    $hash->{STATE} = 'Started';
		RemoveInternalTimer($hash);
 
		$hash->{LOCAL} = 1;
		Tado_GetUpdate($hash);
		delete $hash->{LOCAL};
	
		InternalTimer(gettimeofday()+$hash->{INTERVAL}, "Tado_GetUpdate", $hash);
	    
		Log3 $name, 1, "Tado_Set $name: Updated readings and started timer to automatically update readings with interval $hash->{INTERVAL}";  
	
	
	} elsif ($opt eq "stop"){
	
		RemoveInternalTimer($hash);
		Log3 $name, 1, "Tado_Set $name: Stopped the timer to automatically update readings";  
        $hash->{STATE} = 'Initialized';
        return undef;
		
	} elsif ($opt eq "interval"){
	
		my $interval = shift @param;

		$interval= 60 unless defined($interval);
		if( $interval < 5 ) { $interval = 5; }

		Log3 $name, 1, "Tado_Set $name: Set interval to" . $interval;

		$hash->{INTERVAL} = $interval;
		setKeyValue(  "Tado_".$hash->{Interval}, $param[4] );
	
	
	}
}

sub Tado_Attr(@) {
	return undef;
}

sub Tado_GetHomes($){
	
	my ($hash) = @_;
	my $name = $hash->{NAME};


	if (not defined $hash){
        my $msg = "Error on Tado_GetHomes. Missing hash variable";
        Log3 'Tado', 1, $msg;
        return $msg; 
    
    }


	my $readTemplate = $url{"getHomeId"};
	   
	my $passwd = urlEncode($hash->{Password});
	my $user = urlEncode($hash->{Username});

	$readTemplate =~ s/#Username#/$user/g;
	$readTemplate =~ s/#Password#/$passwd/g;
   
	my $d = Tado_httpSimpleOperation( $hash , $readTemplate, 'GET' );

	if (defined $d && ref($d) eq "HASH" && defined $d->{errors}){
    
    	$hash->{STATE} = "Error: $d->{errors}[0]->{code} / $d->{errors}[0]->{title}";	
    	return undef;
    	    
    } else {
    
		readingsBeginUpdate($hash);
		readingsBulkUpdate($hash, "HomeID", $d->{homes}[0]->{id} );
		readingsBulkUpdate($hash, "HomeName", $d->{homes}[0]->{name});
		readingsEndUpdate($hash, 1);	

		$hash->{HomeID} = $d->{homes}[0]->{id};
		$hash->{HomeName} = $d->{homes}[0]->{name};

		Log3 $name, 1, "New Tado Home defined. Id: $hash->{HomeID} Name: $hash->{HomeName}"; 


		if (scalar (@{$d->{homes}}) > 1 ){
			readingsBeginUpdate($hash);
			readingsBulkUpdate($hash, "HomeID_2", $d->{homes}[1]->{id} );
			readingsBulkUpdate($hash, "HomeName_2", $d->{homes}[1]->{name});
			readingsEndUpdate($hash, 1);	

			$hash->{HomeID_2} = $d->{homes}[1]->{id};
			$hash->{HomeName_2} = $d->{homes}[1]->{name};
		}

		$hash->{STATE} = 'Initialized';
		return undef;
    }

}

sub Tado_GetZones($){
	
	my ($hash) = @_;
	my $name = $hash->{NAME};

	if (not defined $hash){
        my $msg = "Error on Tado_GetZones. Missing hash variable";
        Log3 'Tado', 1, $msg;
        return $msg; 
    
    }
    
    if (not defined $hash->{"HomeID"}){
        my $msg = "Error on Tado_GetZones. Missing HomeID. Please define Home first.";
        Log3 'Tado', 1, $msg;
        return $msg; 
    
    }

	my $readTemplate = $url{"getZoneDetails"};
	   
	my $passwd = urlEncode($hash->{Password});
	my $user = urlEncode($hash->{Username});


	$readTemplate =~ s/#HomeID#/$hash->{HomeID}/g;
	$readTemplate =~ s/#Username#/$user/g;
	$readTemplate =~ s/#Password#/$passwd/g;


	my $d = Tado_httpSimpleOperation( $hash , $readTemplate, 'GET'  );
    
	if (defined $d && ref($d) eq "HASH" && defined $d->{errors}){
       log 1, Dumper $d;
   	$hash->{STATE} = "Error: $d->{errors}[0]->{code} / $d->{errors}[0]->{title}";	
   	return undef;
   
   } else {


	readingsBeginUpdate($hash);

	for my $item( @{$d} ){
	   
	   	readingsBulkUpdate($hash, "Zone_" . $item->{id} . "_ID"  , $item->{id} );
	   	readingsBulkUpdate($hash, "Zone_" . $item->{id} . "_Name"  , $item->{name} );
	   	readingsBulkUpdate($hash, "Zone_" . $item->{id} . "_Type"  , $item->{type} );
	   	readingsBulkUpdate($hash, "Zone_" . $item->{id} . "_DateCreated"  , $item->{dateCreated} );
	   	readingsBulkUpdate($hash, "Zone_" . $item->{id} . "_SupportsDazzle"  , $item->{supportsDazzle} );
  
        $hash->{"Zones"} = $item->{id};
  
	   	$hash->{"Zone_" . $item->{id} . "_ID"} = $item->{id}; 
	   	$hash->{"Zone_" . $item->{id} . "_Name"} = $item->{name};
	   	$hash->{"Zone_" . $item->{id} . "_Type"} = $item->{type};
	   	$hash->{"Zone_" . $item->{id} . "_DateCreated"} = $item->{dateCreated};
	   	$hash->{"Zone_" . $item->{id} . "_SupportsDazzle"} = $item->{supportsDazzle};
   
	   

        my $code = $name ."-". $item->{id};
        
    	if( defined($modules{TadoDevice}{defptr}{$code}) ) {
      		Log3 $name, 5, "$name: id '$item->{id}' already defined as '$modules{TadoDevice}{defptr}{$code}->{NAME}'";
    	} else {
    	
    	   
    		my $deviceName = "Tado_" . $item->{name};
	   		$deviceName =~ s/ /_/g;
	   		my $define= "$deviceName TadoDevice $item->{id} IODev=$name";
   
	   		Log3 $name, 1, "Tado_GetZones ($name): create new device '$deviceName' for zone '$item->{id}'";

	   		my $cmdret= CommandDefine(undef,$define);
    	
    		if(defined $cmdret) {
	   		if( not index($cmdret, 'already defined') != -1) {
	   		   Log3 $name, 1, "$name: Autocreate: An error occurred while creating device for id '$item->{id}': $cmdret";
	   		}  
	   		} else {
		   		CommandAttr(undef,"$deviceName room Tado");
		   		CommandAttr(undef,"$deviceName subType zone");
			}
    	
    	}

		
	}
	readingsEndUpdate($hash, 1);	

	return undef;

	}

}

sub Tado_GetDevices($){
	
	my ($hash) = @_;
	my $name = $hash->{NAME};


	my $readTemplate = $url{"getDevices"};
	   
	my $passwd = urlEncode($hash->{Password});
	my $user = urlEncode($hash->{Username});


	$readTemplate =~ s/#HomeID#/$hash->{HomeID}/g;
	$readTemplate =~ s/#Username#/$user/g;
	$readTemplate =~ s/#Password#/$passwd/g;


	my $d = Tado_httpSimpleOperation( $hash , $readTemplate, 'GET'  );
    
	if (defined $d && ref($d) eq "HASH" && defined $d->{errors}){
       log 1, Dumper $d;
   	$hash->{STATE} = "Error: $d->{errors}[0]->{code} / $d->{errors}[0]->{title}";	
   	return undef;
   
   } else {


	readingsBeginUpdate($hash);

     my $count = 0;
	for my $item( @{$d} ){
	    $count++;
        $hash->{Devices} = $item->{$count};
  
        my $code = $name ."-". $item->{serialNo};
        
    	if( defined($modules{TadoDevice}{defptr}{$code}) ) {
      		Log3 $name, 5, "Tado_GetDevices ($name): device id '$item->{id}' already defined as '$modules{TadoDevice}{defptr}{$code}->{NAME}'";
    	} else {
    	
    		my $deviceName = "Tado_" . $item->{serialNo};
	   		$deviceName =~ s/ /_/g;
	   		my $define= "$deviceName TadoDevice $item->{serialNo} IODev=$name";
   
	   		Log3 $name, 1, "Tado_GetDevices ($name): create new device '$deviceName' for zone '$item->{id}'";

	   		my $cmdret= CommandDefine(undef,$define);
    	
    		if(defined $cmdret) {
	   			if( not index($cmdret, 'already defined') != -1) {
	   		   		Log3 $name, 1, "$name: Autocreate: An error occurred while creating device for id '$item->{id}': $cmdret";
	   			}  
	   		} else {
	   		
	   		    my $deviceHash = $modules{TadoDevice}{defptr}{$code};
	   		    
		   		CommandAttr(undef,"$deviceName room Tado");
		   		if ($item->{deviceType} eq 'IB01'){	
			   		CommandAttr(undef,"$deviceName subType bridge");
			   		$deviceHash->{deviceType} = $item->{deviceType};
			   		$deviceHash->{serialNo} = $item->{serialNo};
			   		$deviceHash->{shortSerialNo} = $item->{shortSerialNo};
			   		$deviceHash->{currentFwVersion} = $item->{currentFwVersion};
			   		$deviceHash->{inPairingMode} = $item->{inPairingMode};
			   		$deviceHash->{capabilities} = join(" ", $item->{characteristics}->{capabilities});
				} else {	   		
		   			CommandAttr(undef,"$deviceName subType thermostat");
			   		$deviceHash->{deviceType} = $item->{deviceType};
			   		$deviceHash->{serialNo} = $item->{serialNo};
			   		$deviceHash->{shortSerialNo} = $item->{shortSerialNo};
			   		$deviceHash->{currentFwVersion} = $item->{currentFwVersion};
			   		$deviceHash->{batteryState} = $item->{inPairingMode};
			   		$deviceHash->{capabilities} = join(" ", $item->{characteristics}->{capabilities});
		   		}
			}
    	}

		
	}
	readingsEndUpdate($hash, 1);	

	return undef;

	}

}

sub Tado_DefineWeatherChannel($){
	
	my ($hash) = @_;
	my $name = $hash->{NAME};

	if (not defined $hash){
        my $msg = "Error on Tado_DefineWeatherChannel. Missing hash variable";
        Log3 'Tado', 1, $msg;
        return $msg; 
    
    }
    
    if (not defined $hash->{"HomeID"}){
        my $msg = "Error on Tado_DefineWeatherChannel. Missing HomeID. Please define Home first.";
        Log3 'Tado', 1, $msg;
        return $msg; 
    
    }

    my $code = $name ."-weather";
        
    	if( defined($modules{TadoDevice}{defptr}{$code}) ) {
    	    my $msg = "Tado_GetDevices ($name): weather device already defined as '$modules{TadoDevice}{defptr}{$code}->{NAME}'";
      		Log3 $name, 5, $msg;
    	} else {
    	
    		my $deviceName = "Tado_Weather";
	   		$deviceName =~ s/ /_/g;
	   		my $define= "$deviceName TadoDevice weather IODev=$name";
   
	   		Log3 $name, 1, "Tado_DefineWeatherChannel ($name): create new device '$deviceName'.";

	   		my $cmdret= CommandDefine(undef,$define);
    	
    		if(defined $cmdret) {
	   			if( not index($cmdret, 'already defined') != -1) {
	   		   		Log3 $name, 1, "$name: Autocreate: An error occurred while creating weather device': $cmdret";
	   			}  
	   		} else {
	   		
	   		    my $deviceHash = $modules{TadoDevice}{defptr}{$code};
	   		    
		   		CommandAttr(undef,"$deviceName room Tado");
			   	CommandAttr(undef,"$deviceName subType weather");
			   	Tado_UpdateWeather($hash);
		   	}
	}
	return undef;
}

sub Tado_GetEarlyStart($){
	
	my ($hash) = @_;
	my $name = $hash->{NAME};

 	if (not defined $hash){
        Log3 $name, 1, "Erro in Tado_GetEarlyStart: No zones defined. Define zones first." if (undef $hash->{"Zones"});
        return undef; 
    }

  	for (my $i=1; $i <= $hash->{"Zones"}; $i++) {

		my $readTemplate = $url{"earlyStart"};
	   
		my $passwd = urlEncode($hash->{Password});
		my $user = urlEncode($hash->{Username});
	   
		my $ZoneName = "Zone_" . $i . "_ID";
	   
		$readTemplate =~ s/#HomeID#/$hash->{HomeID}/g;
    	$readTemplate =~ s/#ZoneID#/$hash->{$ZoneName}/g;
    	$readTemplate =~ s/#Username#/$user/g;
    	$readTemplate =~ s/#Password#/$passwd/g;
       
		my $d = Tado_httpSimpleOperation( $hash , $readTemplate, 'GET'  );

		my $message = "Tado;$i;earlyStart;$d->{enabled}";

		Log3 $name, 4, "$name: trying to dispatch message: $message"; 
       	my $found = Dispatch($hash, $message);
       	Log3 $name, 4, "$name: tried to dispatch message. Result: $found";
	}
		return undef;
}

sub Tado_UpdateWeather($){
  my ($hash) = @_;
  my $name = $hash->{NAME};

    if (not defined $hash){
        Log3 'Tado', 1, "Error on Tado_GetWeather. Missing hash variable";
        return undef; 
    
    }
    
    my $code = $name ."-weather";
        
    if (not defined($modules{TadoDevice}{defptr}{$code})) {
      		Log3 $name, 3, "Tado_UpdateWeather ($name) : Not updating weather channel as it is not defined.";
      		return undef;
    }
    	        
 
  Log3 $name, 4, "Tado_UpdateWeather Called. Name: $name"; 


	my $readTemplate = $url{"getWeather"};
	   
	my $passwd = urlEncode($hash->{Password});
	my $user = urlEncode($hash->{Username});


	$readTemplate =~ s/#HomeID#/$hash->{HomeID}/g;
	$readTemplate =~ s/#Username#/$user/g;
	$readTemplate =~ s/#Password#/$passwd/g;


	my $d = Tado_httpSimpleOperation( $hash , $readTemplate, 'GET'  );
    
	if (defined $d && ref($d) eq "HASH" && defined $d->{errors}){
       log 1, Dumper $d;
   	$hash->{STATE} = "Error: $d->{errors}[0]->{code} / $d->{errors}[0]->{title}";	
   	return undef;
   
   } else {

      # Readings updaten
       readingsBeginUpdate($hash);
       
     
       readingsEndUpdate($hash, 1);
       
       my $overlay =  defined $d->{overlay} ? 1 : 0;
       
       my $message = "Tado;weather;weather;" 
       . $d->{solarIntensity}->{percentage} . ";"
       . $d->{solarIntensity}->{timestamp} . ";"
       . $d->{outsideTemperature}->{celsius} . ";"
       . $d->{outsideTemperature}->{timestamp} . ";"
       . $d->{weatherState}->{value} . ";"
       . $d->{weatherState}->{timestamp};
       
		Log3 $name, 4, "$name: trying to dispatch message: $message"; 
       	my $found = Dispatch($hash, $message);
       	Log3 $name, 4, "$name: tried to dispatch message. Result: $found";       	
	}
	
	return undef;
}

sub Tado_GetUpdate($){
  my ($hash) = @_;
  my $name = $hash->{NAME};

    if (not defined $hash){
        Log3 'Tado', 1, "Error on Tado_GetUpdate. Missing hash variable";
        return undef; 
    
    }
    
    if (not defined $hash->{"Zones"}){
        Log3 'Tado', 1, "Error on Tado_GetUpdate. Missing zones. Please define zones first.";
        return undef; 
    
    }
    
        
 
  Log3 $name, 4, "Tado_GetUpdate Called. Name: $name";  


  #local allows call of function without adding new timer.
  #must be set before call ($hash->{LOCAL} = 1) and removed after (delete $hash->{LOCAL};)
  if(!$hash->{LOCAL}) {
    RemoveInternalTimer($hash);
    #Log3 "Test", 1, Dumper($hash);  
    InternalTimer(gettimeofday()+$hash->{INTERVAL}, "Tado_GetUpdate", $hash);
    $hash->{STATE} = 'Polling';
  }


  Log3 $name, 3, "Getting update for $hash->{Zones} zones.";

  for (my $i=1; $i <= $hash->{Zones}; $i++) {

	my $readTemplate = $url{"getZoneTemperature"};
	   
	my $passwd = urlEncode($hash->{Password});
	my $user = urlEncode($hash->{Username});
	   
	my $ZoneName = "Zone_" . $i . "_ID";
	   
	$readTemplate =~ s/#HomeID#/$hash->{HomeID}/g;
    $readTemplate =~ s/#ZoneID#/$hash->{$ZoneName}/g;
    $readTemplate =~ s/#Username#/$user/g;
    $readTemplate =~ s/#Password#/$passwd/g;
       
	my $d = Tado_httpSimpleOperation( $hash , $readTemplate , 'GET' );

	if (defined $d && ref($d) eq "HASH" && defined $d->{errors}){
       log 1, Dumper $d;
   	   $hash->{STATE} = "Error: $d->{errors}[0]->{code} / $d->{errors}[0]->{title}";	
   	   return undef;
    } else {

       
       # Readings updaten
       readingsBeginUpdate($hash);
       
     
       readingsEndUpdate($hash, 1);
       
       my $overlay =  defined $d->{overlay} ? 1 : 0;
       
       my $message = "Tado;$i;temp;" 
       #measured-temp
       . $d->{sensorDataPoints}->{insideTemperature}->{celsius} . ";"
       #measured-temp-timestamp
       . $d->{sensorDataPoints}->{insideTemperature}->{timestamp} . ";"
       #measured-temp-fahrenheit
       . $d->{sensorDataPoints}->{insideTemperature}->{fahrenheit} . ";"
       #measured-temp-precision
       . $d->{sensorDataPoints}->{insideTemperature}->{precision}->{celsius} . ";"
       #measured-temp-precision-fahrenheit
       . $d->{sensorDataPoints}->{insideTemperature}->{precision}->{fahrenheit} . ";"
       #desired-temp
       . $d->{setting}->{temperature}->{celsius}. ";"
       
       #measured-humidity
       . $d->{sensorDataPoints}->{humidity}->{percentage} . ";"
       #measured-humidity-timestamp
       . $d->{sensorDataPoints}->{humidity}->{timestamp} . ";"
       #link
       . $d->{link}->{state} . ";"
       #open-window
       . $d->{openWindow} . ";"
       #heating-percentage
       . $d->{activityDataPoints}->{heatingPower}->{percentage} . ";"
       #heating-percentage-timestamp
       . $d->{activityDataPoints}->{heatingPower}->{timestamp} . ";"
       
       
       #nextScheduleChange-temperature
       . $d->{nextScheduleChange}->{setting}->{temperature}->{celsius} . ";"
       #nextScheduleChange-power
       . $d->{nextScheduleChange}->{setting}->{power} . ";"
       #nextScheduleChange-start
       . $d->{nextScheduleChange}->{start} . ";"
       
       
       #overlay-active
       . $overlay; 
       
       if ($overlay) {     
          $message .= ";"
		   #overlay-mode
		   . $d->{overlay}->{type} . ";"
		   #overlay-power
		   . $d->{overlay}->{setting}->{power} . ";"
		   #overlay-desired-temperature
		   . $d->{overlay}->{setting}->{temperature}->{celsius} . ";"
		   #overlay-termination-mode
		   . $d->{overlay}->{termination}->{type} . ";"
		   #overlay-termination-durationInSeconds
		   . $d->{overlay}->{termination}->{durationInSeconds} . ";"
		   #overlay-overlay-termination-expiry
		   . $d->{overlay}->{termination}->{expiry} . ";"
		   #overlay-overlay-termination-remainingTimeInSeconds
		   . $d->{overlay}->{termination}->{remainingTimeInSeconds};   
		}
		Log3 $name, 4, "$name: trying to dispatch message: $message"; 
       	my $found = Dispatch($hash, $message);
       	Log3 $name, 4, "$name: tried to dispatch message. Result: $found";
	}
	
	}
	readingsBeginUpdate($hash);
	readingsBulkUpdate($hash, "LastUpdate", localtime );
	readingsEndUpdate($hash, 1);
	
    return undef;
	
}

sub Tado_Write ($$){
	my ($hash,$code,$zoneID,$param1,$param2)= @_;
	my $name = $hash->{NAME};
	
	if ($code eq 'Temp')
	{
	    my $duration = $param1;
	    my $temperature = $param2;
	  
		my $readTemplate = $url{"setZoneTemperature"};
	   
		my $passwd = urlEncode($hash->{Password});
		my $user = urlEncode($hash->{Username});
		   
		$readTemplate =~ s/#HomeID#/$hash->{HomeID}/g;
		$readTemplate =~ s/#ZoneID#/$zoneID/g;
		$readTemplate =~ s/#Username#/$user/g;
		$readTemplate =~ s/#Password#/$passwd/g;
		
	    my %message ;
	    $message{'setting'}{'type'} = "HEATING";
	    $message{'setting'}{'power'} = 'ON';
	    $message{'setting'}{'temperature'} {'celsius'} =  $temperature + 0 ;
	    $message{'termination'}{'type'}  = 'TIMER';
	    $message{'termination'}{'durationInSeconds'} = $duration * 60;
	                    
	    if ($duration eq "0") {$message{'termination'}{'type'}  = 'MANUAL';}                
	    
        if ($duration eq 'Auto'){
        	 Log3 $name, 1, 'Return to automatic mode';
        	my $d = Tado_httpSimpleOperation( $hash , $readTemplate, 'DELETE'  );
        } else {
			my $d = Tado_httpSimpleOperation( $hash , $readTemplate, 'PUT',  encode_json \%message  );
		}
    } 
 
	if ($code eq 'EarlyStart')
	{
	   my $setting = $param1;
	   
		my $readTemplate = $url{"earlyStart"};
	   
		my $passwd = urlEncode($hash->{Password});
		my $user = urlEncode($hash->{Username});
		   
		$readTemplate =~ s/#HomeID#/$hash->{HomeID}/g;
		$readTemplate =~ s/#ZoneID#/$zoneID/g;
		$readTemplate =~ s/#Username#/$user/g;
		$readTemplate =~ s/#Password#/$passwd/g;
		
	    my %message ;
	    $message{'enabled'} = $setting;
	                    
		my $d = Tado_httpSimpleOperation( $hash , $readTemplate, 'PUT' , encode_json \%message  );
        
        if (defined $d && ref($d) eq "HASH" && defined $d->{errors}){
    		return "Error: $d->{errors}[0]->{code} / $d->{errors}[0]->{title}";	
    	}
    	
    	return $d->{enabled};

    }   
    
    
    if ($code eq 'Update')
	{  
		Tado_GetUpdate($hash);
		Tado_UpdateWeather($hash);
    }  
    
    
    if ($code eq 'Hi')
	{
	   
		my $readTemplate = $url{"identifyDevice"};
	   
		my $passwd = urlEncode($hash->{Password});
		my $user = urlEncode($hash->{Username});
		   
		$readTemplate =~ s/#DeviceId#/$zoneID/g;
		$readTemplate =~ s/#Username#/$user/g;
		$readTemplate =~ s/#Password#/$passwd/g;
	                    
		my $d = Tado_httpSimpleOperation( $hash , $readTemplate, 'POST'  );
        
        if (defined $d && ref($d) eq "HASH" && defined $d->{errors}){
    		return "Error: $d->{errors}[0]->{code} / $d->{errors}[0]->{title}";	
    	}
    	
    	return $d->{enabled};

    }   
    
	
	
	return undef;
}


1;

=pod
=begin html

<a name="Tado"></a>
<h3>Tado</h3>
<ul>
    <i>Tado</i> implements an interface to the Tado cloud. The plugin can be used to read and write 
    temperature and settings from or to the Tado cloud. The communication is based on the reengineering of the protocol done by
    Stephen C. Phillips. See <a href="http://blog.scphillips.com/posts/2017/01/the-tado-api-v2/">his blog</a> for more details.
    Not all functions are implemented within this FHEM extension. By now the plugin is capable to 
    interact with the so called zones (rooms) and the registered devices. The devices cannot be 
    controlled directly. All interaction - like setting a temperature - must be done via the zone and not the device.
    This means all configuration like the registration of new devices or the assignment of a device to a room 
    must be done using the Tado app or Tado website directly. Once the configuration is completed this plugin can
    be used.
    This device is the 'bridge device' like a HueBridge or a CUL. Per zone or device a dedicated device of type 
    'TadoDevice' will be created.
    <br><br>
    <a name="Tadodefine"></a>
    <b>Define</b>
    <ul>
        <code>define &lt;name&gt; Tado &lt;username&gt; &lt;password&gt; &lt;interval&gt;</code>
        <br><br>
        Example: <code>define TadoBridge Tado mail@provider.com somepassword 120</code>
        <br><br>
        The username and password must match the username and password used on the Tado website.
        Please be aware that username and password are stored and send as plain text. They are visible in FHEM user interface.
        It is recommended to create a dedicated user account for the FHEM integration.
        The Tado extension needs to pull the data from the Tado website. The 'Interval' value defines how often the value is refreshed.
    </ul>
    <br>
    
    <a name="Tasoset"></a>
    <b>Set</b><br>
    <ul>
        <code>set &lt;name&gt; &lt;option&gt;</code>
        <br><br>
        The <i>set</i> command just offers very limited options.
        If can be used to control the refresh mechanism. The plugin only evaluates
        the command. Any additional information is ignored.
        <br><br>
        Options:
        <ul>
              <li><i>interval</i><br>
                  Sets how often the values shall be refreshed.
                  This setting overwrites the value set during define.</li>
              <li><i>start</i><br>
                  (Re)starts the automatic refresh.
                  Refresh is autostarted on define but can be stopped using stop command. Using the start command FHEM will start polling again.</li>
              <li><i>stop</i><br>
                  Stops the automatic polling used to refresh all values.</li>
        </ul>
    </ul>
    <br>

    <a name="Tadoget"></a>
    <b>Get</b><br>
    <ul>
        <code>get &lt;name&gt; &lt;option&gt;</code>
        <br><br>
        You can <i>get</i> the major information from the Tado cloud.
 		<br><br>
        Options:
        <ul>
              <li><i>home</i><br>
                  Gets the home identifier from Tado cloud. 
                  The home identifier is required for all further actions towards the Tado cloud.
                  Currently the FHEM extension only supports a single home. If you have more than one home only the first home is loaded.
                  <br/><b>This function is automatically executed once when a new Tado device is defined.</b></li>
              <li><i>zones</i><br>
                  Every zone in the Tado cloud represents a room.
                  This command gets all zones defined for the current home.
                  Per zone a new FHEM device is created. The device can be used to display and 
                  overwrite the current temperatures.
                  This command can always be executed to update the list of defined zones. It will not touch any existing 
                  zone but add new zones added since last update.
                  <br/><b>This function is automatically executed once when a new Tado device is defined.</b></li>
                  </li>
              <li><i>devices</i><br>
                  Fetches all devices from Tado cloud and creates one TadoDevice instance
                  per fetched device.
                  This command can always be executed to update the list of defined devices. 
                  It will not touch existing devices but add new ones.
                  </li>
              <li><i>update</i><br>
                  Updates the values of all Tado zones - not the tado devices.</li>
        </ul>              
    </ul>
    <br>
    
    <a name="Tadoattr"></a>
    <b>Attributes</b>
    <ul>
        <code>attr &lt;name&gt; &lt;attribute&gt; &lt;value&gt;</code>
        <br><br>
        No attributes so far...
    </ul>
</ul>

=end html

=cut