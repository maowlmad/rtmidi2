# rtmidi2

Python wrapper for [RtMidi](http://www.music.mcgill.ca/~gary/rtmidi/), the
lightweight, cross-platform MIDI I/O library. For Linux, Mac OS X and Windows.

Based on rtmidi-python

## Setup

The wrapper is written in [Cython](http://www.cython.org). Cython should
be installed for this module to be installed. RtMidi is included in the source tree, so you only need to do:

    python setup.py install
    
## Python 2 & 3

Thanks to Cython, this module is both compatible with Python 2 and Python 3. The only visible difference is that under python 3, all strings are byte strings. If you pass a unicode string to any function taking a string (open_virtual_port), an attempt will be made to encode the string as ASCII, through .encode("ASCII", errors="ignore"). 

## Usage Examples

_rtmidi2_ uses a very similar API as RtMidi

### Print all in and out ports

```python
import rtmidi2
print(rtmidi2.get_in_ports())
print(rtmidi2.get_out_ports())
```

### Send messages

```python
import rtmidi2
  
midi_out = rtmidi2.MidiOut()
# open the first available port
midi_out.open_port(0) 
# send C3 with vel. 100 on channel 1
midi_out.send_noteon(0, 48, 100)
```

### Get incoming messages - blocking interface

```python
midi_in = rtmidi.MidiIn()
midi_in.open_port(0)

while True:
    message, delta_time = midi_in.get_message()  # will block until a message is available
    if message:
        print(message, delta_time)
```

### Get incoming messages using a callback -- non blocking

```python
def callback(message, time_stamp):
    print(message, time_stamp)

midi_in = rtmidi2.MidiIn()
midi_in.callback = callback
midi_in.open_port(0)
``` 


Note that the signature of the callback differs from the original RtMidi API:
`message` is now the first parameter, like in the tuple returned by
`get_message()`.

### Open multiple ports at once
   
```python
# get messages from all available ports
midi_in = MidiInMulti().open_ports("*")

def callback(msg, timestamp):
    msgtype, channel = splitchannel(msg[0])
    print(msgtype2str(msgtype), msg[1], msg[2])

midi_in.callback = callback
```

You can also get the device which generated the event by changing your callback to:

```python
def callback(src, msg, timestamp):
    # src will hold the name of the device
    print("got message from", src)
```

               
### Send multiple notes at once

The usecase for this is limited to a few niche-cases, but was the reason why 
this fork was initiated in the first place. I needed a fast way to send multiple 
notes at once for an application transcribing the spectrum of a voice to 
midi messages to be played by an automated piano.

```python
# send a cluster of ALL notes with a duration of 1 second
midi_out = MidiOut().open_port()
notes = range(127)
velocities = [90] * len(notes)
midi_out.send_noteon_many(0, notes, velocities)
time.sleep(1)
midi_out.send_noteon_many(0, notes, [0] * len(notes))
```

## License

_rtmidi2_ is licensed under the MIT License, see `LICENSE`.

It uses RtMidi, licensed under a modified MIT License, see `RtMidi/RtMidi.h`.
