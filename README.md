
# Sharem

File and Text Sharing utility on local network

```
    sharem_cli [command] <options>
    
    commands:
      send
          -n receiver_name required
          -t flag reads from stdin and sends to receiver
          -f file paths to send
      recv
          -n your_name if not passed, generates a unique name
      list
          lists nearby active peers
    Example Usage:
      sharem_cli recv -n JaneDoe
      echo 'Hello World' | sharem_cli send -n  JaneDoe
      sharem_cli send -n JaneDoe -f ./README.md -f ./cat-video.mp4
      sharem_cli list
```


# Enivronment Variables

SHAREM_SAVE_DIR defaults to /tmp/

SHAREM_BROADCAST_ADDR for development uses 127.0.0.1, but should be set to 255.255.255.255
