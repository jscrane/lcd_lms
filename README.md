# lcd_lms
Script to glue the Logitect Media Server 
[command-line](http://wiki.slimdevices.com/index.php/Logitech_Media_Server_CLI) to LCDd.

## Example:
Connect to LCDd on host _displayserver_ and the player _Squeezelite_ on host _mediaserver_, and debug the _lms_ protocol.

```
$ ./lcd_lms.pl -v lms -d displayserver -l mediaserver SqueezeLite
```