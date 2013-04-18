# rtmidi2

Python wrapper for [RtMidi](http://www.music.mcgill.ca/~gary/rtmidi/), the
lightweight, cross-platform MIDI I/O library. For Linux, Mac OS X and Windows.

Based on rtmidi-python

## Setup

The wrapper is written in [Cython](http://www.cython.org), but the generated
C++ code is included, so you can install the module as usual:

    python setup.py install

If you want to build from the Cython source, make sure that you have a recent
version of Cython (>= 0.15), and run:

    python setup.py install --from-cython

## Usage Examples

_rtmidi2_ uses the same API as RtMidi, only reformatted to comply with PEP-8,
and with small changes to make it a little more pythonic.

### Print all output ports

    import rtmidi2 as rtmidi

    midi_out = rtmidi.MidiOut()
    for port_name in midi_out.ports:
        print port_name

### Send messages

    import rtmidi2 as rtmidi

    midi_out = rtmidi.MidiOut()
    midi_out.open_port(0)

    midi_out.send_noteon(0, 48, 100)  # send C3 with vel 100 on channel 1

### Get incoming messages - blocking interface

    midi_in = rtmidi.MidiIn()
    midi_in.open_port(0)

    while True:
        message, delta_time = midi_in.get_message()  # will block until a message is available
        if message:
            print message, delta_time

Note that the signature of `get_message()` differs from the original RtMidi
API: It returns a tuple (message, delta_time)

### Get incoming messages using a callback -- non blocking

    def callback(message, time_stamp):
        print message, time_stamp

    midi_in = rtmidi.MidiIn()
    midi_in.callback = callback
    midi_in.open_port(0)

    # do something else here (but don't quit)
    ...

Note that the signature of the callback differs from the original RtMidi API:
`message` is now the first parameter, like in the tuple returned by
`get_message()`.

### Open multiple ports at once
   
    midi_in = MidiInMulti().open_ports("*")
    def callback(msg, timestamp):
        msgtype, channel = splitchannel(msg[0])
        print msgtype2str(msgtype), msg[1], msg[2]
    midi_in.callback = callback
    
You can also get the device which generated the event by changing your callback to:

    def callback(src, msg, timestamp):
        print "got message from", src     # src will hold the name of the device
        
### Send multiple notes at once

The usecase for this is limited to a few niche-cases, but was the reason why I initiated
this fork on the first place. I needed a fast way to send multiple notes at once for
an application transcribing the spectrum of a voice to midi messages to be played
by an automated piano.

    # send a cluster of ALL notes with a duration of 1 second
    midi_out = MidiOut().open_port()
    notes = range(127)
    velocities = [90] * len(notes)
    midi_out.send_noteon_many(0, notes, velocities)
    time.sleep(1)
    midi_out.send_noteon_many(0, notes, [0] * len(notes))

## License

_rtmidi2_ is licensed under the MIT License, see `LICENSE`.

It uses RtMidi, licensed under a modified MIT License, see `RtMidi/RtMidi.h`.
