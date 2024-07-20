
# If the driver is already loaded, stops time updates and
# closes the serial port, allowing to reload the code
# this is useful when developing "gnsstime.be"
if global.gnsstime!=nil
  global.gnsstime.stop()
end

def gnsstime_func()
  import strict
  import string

  var MSG = 'GNSS : '

  class GnssTime # We need just one instance of this, look after the end of the class

    var buf # holds the serial port incoming bytes
    var millis # to detect a timeout
    var silence_millis # used to detect the silence before and after NMEA sentences emmition
    var state # state machine while parsing the sentence
    var ser # the serial port instance
    var fast_loop_closure # we hold it in a var to be able to cancel it
    var working # flag to prevent a second update() to run in parallel with the first
    #var gotsentence # true if we have at least 1 sentence with correct checksum since the load of the module
    var gottime # true if we have at least 1 succesful time from GNSS
    var update_interval # The update interval in milliseconds
    # var first_sentence # The first sentence after update ie 'GGA' who happens to be read
    # var debug_flag
    var snr

    # variable initialization
    def init()
      self.update_interval = 0
      #self.gotsentence = false
      self.gottime = false
      self.fast_loop_closure = def () self._fast_loop() end
      #self.debug_flag = false
    end

    # opens the serial port
    def start(pin, baud)
      self.ser = serial(pin, -1, baud) # opens the serial port
    end

    # Parses the NMEA output and sets the tasmota system time (once)
    def update()
      if self.ser == nil print('You need to call start(pin,baud) first') return end
      if self.working print('already running') return end # we have only one serial port
      self.working = true # we block other .update() to run in parallel
      self.millis = tasmota.millis() # we need it to detect a ~1100ms timeout
      self.silence_millis = tasmota.millis()
      self.state = 1 # the NMEA sentence parsing uses it as a state machine
      self.buf='' # here we store the serial port output as a string
      self.snr=[] # we store the SNR collected from all GSV messages
      self.ser.flush() # We start with an empty serial buffer
      tasmota.add_fast_loop(self.fast_loop_closure) # all work is done here, without blocking the system
    end

    def update_every(sec) # time in seconds, 3600 (1 hour) is OK
      if self.ser == nil print('You need to call start(pin,baud) first') return end
      if type(sec)!='int' && type(sec)!='real'
        print('Need the update interval in seconds')
        return
      end
      #
      tasmota.remove_timer(self)
      #self._stop_fast_loop()
      #
      if sec <= 0
        self.update_interval = 0 
        print('Stopping GNSS time updates, and enabling NTP(via Wifi/ethernet) updates, if available')
        tasmota.cmd('time 0', true)
        return
      end
      #if self.update_interval > 0
      #  print('You must cancel the previous timer first, passing 0 as argument')
      #  return
      #end
      if sec > 86400 # 1 day, there is no reason for more than this
        sec = 86400
        print('Setting interval to' .. sec .. ' sec')
      end
      if sec < 5 # minimum update interval
        # print('Update interval is set to 5 sec')
        sec = 5
      end
      self.update_interval = int(sec * 1000)
      self._update()
    end # member update_every(seconds)

    # Called internally
    def _update()
      tasmota.remove_timer(self)
      if self.update_interval==0 # self.update_interval is in milliseconds
        print('_update() called with disabled automatic updates')
        return
      end
      var interval
      if tasmota.millis()>5000 # Wait for tasmota boot to finish (5000ms=5sec)
        self.update() # this set fast loop in background and returns
        interval = self.update_interval
        # if there was a problem with the last update,
        # the new will be after 15 sec maximum
        if !self.gottime && self.update_interval>15000
          interval = 15000
        end
      else
        interval = 5100 # 5.1 sec
      end
      tasmota.set_timer(interval, /->self._update(), self )
    end # _update()

    def _check_checksum(buf) # Checks the NMEA checksum
      if size(buf) < 10 return false end
      if buf[-3] != '*'
        # print('No "*" is detected in NMEA sentence')
        return false
      end
      var chk=0
      # The first byte $ in not included in the XOR checksum
      # neither the * and of course the checksum itself
      for i:range(1, size(buf)-4)
        chk ^= string.byte(buf[i])
      end
      return int('0x' + buf[-2..-1]) == chk
    end

    def parse_sentence(buf)
      if size(buf)<10 return end
      if buf[0]!='$' return end
      if !self._check_checksum(buf)
        print('Wrong NMEA checksum')
        print(buf)
        return
      end
      var sentence = buf[3..5]
      if sentence == 'RMC'
        self._parse_rmc(buf)
      elif sentence == 'GSV'
        self._parse_gsv(buf)
      end
    end

    # appends a SNR value to the list of SNRs
    # from the best to the worst
    def _add_snr(e)
      var i=0
      var snrsize = size(self.snr)
      while(i < snrsize)
        if e >= self.snr[i] break end
        i += 1
      end
      if i == snrsize self.snr.push(e) return end
      self.snr.insert(i, e)
    end

    def _parse_gsv(buf)
      buf = buf[7..-4]
      buf = string.split(buf,',')
      var fields = size(buf)      
      var idx = 6
      while idx<fields
        if buf[idx] != ''
          self._add_snr(int( buf[idx] ))
        end
        idx += 4
      end
    end

    def _parse_rmc(buf)
      # it will be true again, only if we get a correct timestamp
      # at the end of the function
      self.gottime = false
      buf = string.split(buf, ',') # now buf is a list instead of string
      if size(buf)<12 # the message must 12 or 13 number of comma delimited fields
        print('The NMEA RMC sentence has less than 12 fields')
        return
      end # no of fields
      if buf[2]!='A' # The GNSS is NOT active (no satelite signal)
        print(MSG + 'WARNING, no valid satellite mesurement')
      end # active field check
      var gnss_time=buf[1] # See the RMC sentence
      var gnss_date=buf[9] # See the RMC sentence
      if !gnss_time || !gnss_date # happens at power up
        print('the message has no date/time')
        return
      end
      if size(gnss_time) != 9
        print('NMEA time is malformed', gnss_time)
        return
      end
      if size(gnss_date) != 6
        print('NMEA date is malformed', gnss_date)
        return
      end
      # time_fmt is a string like '2024 05 27 16 22 54' suitable for parsing
      var time_fmt ='20'+gnss_date[4..]+' '+gnss_date[2..3]+' '+gnss_date[0..1]+' '+gnss_time[0..1]+' '+gnss_time[2..3]+' '+gnss_time[4..5]
      # converting to a map containing time representations
      var time_strp = tasmota.strptime(time_fmt ,'%Y %m %d %H %M %S')
      if time_strp['unparsed'] # tasmota.strptime failed to parse the string
        print('Error parsing time')
        return
      end
      var epoch = time_strp['epoch']
      if epoch < 1700000000 # a final check, the time cannot be in the past
        print(MSG + 'gnsstime is wrong')
        return
      end
      tasmota.cmd('time ' .. epoch, true)
      self.gottime = true
    end

    def _stop_fast_loop()
      tasmota.remove_fast_loop(self.fast_loop_closure)
      self.buf=''
      self.working = false
      self.snr = ''
    end

    def _fast_loop()
      # Should not happen, this is an error in program logic
      if tasmota.millis()-self.millis > 4000
        print(MSG + 'Timeout (PROGRAM ERROR)')
        self._stop_fast_loop()
        return
      end
      #
      if self.state == 1 # we discard all serial data until we detect silence
        if self.ser.available()
          self.silence_millis = tasmota.millis()
          self.ser.read()
        else
          if tasmota.millis()-self.silence_millis>50
            self.state = 2
          end
        end
        return
      end
      #
      if self.state == 2 # we wait until the GNSS starts sending data
        if ! self.ser.available()
          return
        end
        self.state = 3
      end
      #
      if self.state==3 # we fill self.buf until we detect silence again
        if self.ser.available()
          #
          self.buf += self.ser.read().asstring()
          self.silence_millis = tasmota.millis()
          var loc = string.find(self.buf, '\r\n')
          if loc>0
            var buf = self.buf[0..loc-1] # The sentence without \r\n
            self.buf = self.buf[loc+2..] # we keep the remaining data to the buffer
            self.parse_sentence(buf)
          end
          return
        end
        # we did not receive any data so we check for silence
        if tasmota.millis()-self.silence_millis > 50
          print('SNR =', self.snr)
          self._stop_fast_loop()
          return
        end
        #
      end
      #
      # Should not happen, this is an error in program logic
      if size(self.buf)>2500 # to protect for memory outage,
        print(MSG + 'The buffer is full (PROGRAM ERROR)')
        self._stop_fast_loop()
        return
      end
      #
    end # fast loop will be reexecuted by the runtime as soon as possible

    def stop()
      if self.ser == nil
        print('gnsstime.stop() : already stopped or not started')
        return
      end
      print('gnsstime.stop()')
      tasmota.remove_timer(self) # stop automatic updates
      self._stop_fast_loop() # stop running time update
      self.ser.close() # closes the serial port
      self.ser = nil # this is a signal the instance is stopped
      tasmota.cmd('time 0', true) # allow NTP time to work again
    end

    def deinit()
      print('gnsstime deinit() called by BerryVM') # To know when the garbage collector works
      if self.ser != nil self.stop() end # We check the serial to avoid the stop() message
    end
    
  end # class GnssTime
  # We are inside a function, so we use "global" to set the gnsstime instance as global var
  global.gnsstime = GnssTime()
  
end

# Creates a GnssTime instance called gnsstime (global var)
gnsstime_func()
# We prevent the creation of other instances
gnsstime_func = nil

### If you do not want to touch this file, put these lines in autoexec
### after load('gnsstime')
#global.gnsstime.start(2, 9600) # pin=2 baud=9600
#global.gnsstime.update_every(10) # update the system time every 60 seconds
