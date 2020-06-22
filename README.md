# lcd_lms
Script to glue the Logitech Media Server 
[command-line](http://wiki.slimdevices.com/index.php/Logitech_Media_Server_CLI) to LCDd.

See it in [action](https://programmablehardware.blogspot.ie/2013/06/squeezeplug-lcd.html).

## Running it
Put it in `/usr/local/bin`. Run it from `/etc/rc.local` as follows:

```
(while true; do
  /usr/local/bin/lcd_lms.pl -m SqueezeLite
  sleep 30
done) &
```

## Example:
Connect to LCDd (on host/port _lcdserver_, _lcdport_) and 
the player _Squeezelite_ (on host/port _lmsserver_, _lmsport_) 
and debug the _lms_ protocol. The ports may be omitted and have sensible
defaults

```
$ ./lcd_lms.pl -v lms -d lcdserver:lcdport -l lmsserver:lmsport SqueezeLite
```
