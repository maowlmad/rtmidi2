#cython: boundscheck=False
#cython: embedsignature=True
#cython: checknone=False
from libcpp.string cimport string
from libcpp.vector cimport vector
from cython.operator cimport dereference as deref, preincrement as inc 

cdef extern from "Python.h":
    void PyEval_InitThreads()
from libc.stdlib cimport malloc, free

# Init Python threads and GIL, because RtMidi calls Python from native threads.
# See http://permalink.gmane.org/gmane.comp.python.cython.user/5837
PyEval_InitThreads()

DEF DNOTEON     = 144
DEF DCC         = 176
DEF DNOTEOFF    = 128
DEF DPROGCHANGE = 192
DEF DPITCHWHEEL = 224

NOTEON     = DNOTEON
CC         = DCC
NOTEOFF    = DNOTEOFF
PROGCHANGE = DPROGCHANGE
PITCHWHEEL = DPITCHWHEEL

cdef extern from "RtMidi/RtMidi.h":
    ctypedef void (*RtMidiCallback)(double timeStamp, vector[unsigned char]* message, void* userData)

    cdef cppclass RtMidi:
        void openPort(unsigned int portNumber)
        void openVirtualPort(string portName)
        unsigned int getPortCount()
        string getPortName(unsigned int portNumber)
        void closePort()

    cdef cppclass RtMidiIn(RtMidi):
        RtMidiIn(string clientName, unsigned int queueSizeLimit)
        void setCallback(RtMidiCallback callback, void* userData)
        void cancelCallback()
        void ignoreTypes(bint midiSysex, bint midiTime, bint midiSense)
        double getMessage(vector[unsigned char]* message)


    cdef cppclass RtMidiOut(RtMidi):
        RtMidiOut(string clientName)
        void sendMessage(vector[unsigned char]* message)

cdef class MidiBase:
    cdef RtMidi* baseptr(self):
        return NULL
    def open_port(self, port=0):
        if isinstance(port, int):
            if port > len(self.ports) - 1:
                raise ValueError("port number out of range")
            port_number = port
        else:
            ports = self.ports
            if port in ports:
                port_number = self.ports.index(port)
            else:
                raise ValueError("Port not found")
        self.baseptr().openPort(port_number)
        return self
    def open_virtual_port(self, port_name):
        self.baseptr().openVirtualPort(string(<char*>port_name))
        return self
    property ports:
        def __get__(self):
            return [self.baseptr().getPortName(i).c_str() for i in range(self.baseptr().getPortCount())]
    def close_port(self):
        self.baseptr().closePort()
    def ports_matching(self, pattern):
        """
        return the indexes of the ports which match the glob pattern

        Example
        -------

        # get all ports
        midiin.ports_matching("*")

        # open the IAC port in OSX without having to remember the whole name
        midiin.open_port(midiin.ports_matching("IAC*"))
        """

        import fnmatch
        ports = self.ports
        return [i for i, port in enumerate(ports) if fnmatch.fnmatch(port, pattern)]

cdef void midi_in_callback(double time_stamp, vector[unsigned char]* message_vector, void* py_callback) with gil:
    message = [message_vector.at(i) for i in range(message_vector.size())]
    (<object>py_callback)(message, time_stamp)

cdef class MidiIn(MidiBase):
    cdef RtMidiIn* thisptr
    cdef object py_callback
    def __cinit__(self, clientname="RTMIDI-IN", queuesize=100):
        self.thisptr = new RtMidiIn(string(<char*>clientname), queuesize)
        self.py_callback = None
    def __init__(self, clientname="RTMIDI-IN", queuesize=100):
        """
        It is not necessary to give the client a name.
        queuesize: the size of the queue in bytes.

        Example
        -------

        m_in = MidiIn()
        m_in.open_port()    # will get messages from the default port

        def callback(msg, timestamp):
            msgtype, channel = splitchannel(msg[0])
            if msgtype == NOTEON:
                print "noteon", msg[1], msg[2]
            elif msgtype == CC:
                print "control change", msg[1], msg[2]

        m_in.callback = callback

        # You can cancel the receiving of messages by setting the callback to None
        m_in.callback = None

        # When you are done, close the port
        m_in.close_port()

        NB: If you want to listen from multiple ports, use MidiInMulti

        For blocking interface, use midiin.get_message()
        """
        # this declaration is here so that the docstring gets generated
        pass
    def __dealloc__(self):
        self.py_callback = None
        del self.thisptr
    cdef RtMidi* baseptr(self):
        return self.thisptr
    property callback:
        def __get__(self):
            return self.py_callback
        def __set__(self, callback):
            self.thisptr.cancelCallback()  # cancel previous callback, if any
            self.py_callback = callback
            if self.py_callback is not None:
                self.thisptr.setCallback(midi_in_callback, <void*>self.py_callback)
    def ignore_types(self, midi_sysex=True, midi_time=True, midi_sense=True):
        self.thisptr.ignoreTypes(midi_sysex, midi_time, midi_sense)
    def get_message(self, int gettime=1):
        """
        Blocking interface. For non-blocking interface, use the callback method (midiin.callback = ...)

        if gettime == 1:
            returns (message, delta_time) 
        otherwise returns only message

        where message is [(messagetype | channel), value1, value2]

        To isolate messagetype and channel, do this:

        messagetype = message[0] & 0xF0
        channel     = message[0] & 0x0F

        or use the utility function splitchannel:

        msgtype, channel = splitchannel(message[0])
        """
        cdef vector[unsigned char]* message_vector = new vector[unsigned char]()
        delta_time = self.thisptr.getMessage(message_vector)
        cdef list message
        if not message_vector.empty():
            message = [message_vector.at(i) for i in range(message_vector.size())]
            return (message, delta_time) if gettime == 1 else message
        else:
            return (None, None) if gettime == 1 else None

cdef class MidiInMulti:
    cdef RtMidiIn* inspector
    cdef vector[RtMidiIn *]* ptrs 
    cdef int queuesize
    cdef readonly object clientname
    cdef object py_callback
    cdef list openports
    cdef dict hascallback
    def __cinit__(self, clientname="RTMIDI-IN", queuesize=100):
        self.inspector = new RtMidiIn(string(<char*>"RTMIDI-INSPECTOR"), queuesize)
        self.ptrs = new vector[RtMidiIn *]()
        self.py_callback = None
    def __init__ (self, clientname="RTMIDI-IN", queuesize=100):
        """
        This class implements the capability to listen to multiple inputs at once
        A callback needs to be defined, as in MidiIn, which will be called if any
        of the devices receives any input. 

        NB: you will not be able to see from which device the input came

        Example
        -------

        multi = MidiInMulti().open_ports("*")
        def callback(msg, timestamp):
            print msg
        multi.callback = callback
        """
        self.queuesize = queuesize
        self.clientname = clientname
        self.openports = []
        self.hascallback = {}
    def __dealloc__(self):
        self.close_ports()
        self.inspector.closePort()
        del self.ptrs
        del self.inspector
    def __repr__(self):
        allports = self.ports
        s = " + ".join(allports[port] for port in self.openports)
        return "MidiInMulti ( %s )" % s
    property ports:
        def __get__(self):
            return [self.inspector.getPortName(i).c_str() for i in range(self.inspector.getPortCount())]
    def get_openports(self):
        return self.openports
    def ports_matching(self, pattern):
        """
        return the indexes of the ports which match the glob pattern

        Example
        -------

        # get all ports
        midiin.ports_matching("*")

        # open the IAC port in OSX without having to remember the whole name
        midiin.open_port(midiin.ports_matching("IAC*"))
        """
        import fnmatch
        ports = self.ports
        return [i for i, port in enumerate(ports) if fnmatch.fnmatch(port, pattern)]
    cpdef open_port(self, int port):
        assert port < self.inspector.getPortCount()
        if port in self.openports:
            raise ValueError("Port already open!")
        cdef RtMidiIn* newport = new RtMidiIn(string(<char*>self.clientname), self.queuesize)
        portname = self.inspector.getPortName(port).c_str()
        newport.openPort(port)
        self.ptrs.push_back(newport)
        self.openports.append(port)
        return self
    cpdef open_ports(self, pattern="*"):
        """
        a shortcut for opening many ports at once.
        This is similar to

        for port in midiin.ports_matching(pattern):
            midiin.open_port(port)

        Example
        -------

        # Transpose all notes received one octave up, send them to OUT
        midiin = MidiInMulti().open_ports("*")
        midiout = MidiOut().open_virtual_port("OUT")
        def callback(msg, timestamp):
            msgtype, ch = splitchannel(msg[0])
            if msgtype == NOTEON:
                midiout.send_noteon(ch,  msg[1] + 12, msg[2])
            elif msgtype == NOTEOFF:
                midiout.send_noteoff(ch, msg[1] + 12, msg[2])
        midiin.callback = callback

        """
        matchingports = self.ports_matching(pattern)
        for port in matchingports:
            self.open_port(port)
        return self
    cpdef close_ports(self):
        """closes all ports and deactivates any callback.
        NB: closing of individual ports is not implemented.
        """
        cdef int i
        cdef RtMidiIn* ptr
        for i, port in enumerate(self.openports):
            ptr = self.ptrs.at(i)
            if self.hascallback[port]:
                ptr.cancelCallback()
            ptr.closePort()
        self.ptrs.clear()
        self.openports = []
        self.hascallback = {}
        self.callback = None
    property callback:
        def __get__(self):
            return self.py_callback
        def __set__(self, callback):
            cdef int i
            cdef RtMidiIn* ptr
            self.py_callback = callback
            for i in range(self.ptrs.size()):
                ptr = self.ptrs.at(i)
                port = self.openports[i]
                if self.hascallback.get(port, False):
                    ptr.cancelCallback()
                if callback is not None:
                    ptr.setCallback(midi_in_callback, <void*>callback)
                    self.hascallback[port] = True
    def get_message(self, int gettime=1):
        raise NotImplemented("The blocking interface is not implemented for multiple inputs. Use the callback system")

def splitchannel(int b):
    """
    split the messagetype and the channel as returned by get_message

    msg = midiin.get_message()
    msgtype, channel = splitchannel(msg[0])
    """
    return b & 0xF0, b & 0x0F

def msgtype2str(msgtype):
    return {
        NOTEON:     'NOTEON',
        NOTEOFF:    'NOTEOFF',
        CC:         'CC',
        PITCHWHEEL: 'PITCHWHEEL',
        PROGCHANGE: 'PROGCHANGE'
    }.get(msgtype, 'UNKNOWN')

_notenames = "C C# D D# E F F# G G# A Bb B C".split()

def midi2note(midinote):
    octave = int(midinote / 12) - 1
    pitchindex = midinote % 12
    return "%s%d" % (_notenames[pitchindex], octave)

def mididump_callback(src, msg, t):
    msgt, ch = splitchannel(msg[0])
    msgtstr = msgtype2str(msgt)
    val1 = int(msg[1])
    val2 = int(msg[2])
    print src,
    if msgt == CC:
        print "CC | ch %d | cc %d | val %d" % (ch, val1, val2)
    elif msgt == NOTEON:
        notename = midi2note(val1)
        print "NOTEON | ch %d | note %s (%d) | vel %d" % (ch, notename, val1, val2)
    else:
        print "%s | ch %d | val1 %d | val2 %d" % (msgtstr, ch, val1, val2)

def mididump(port_pattern="*"):
    """
    listen to all ports matching pattern and print the incomming messages
    """
    m = MidiInMulti().open_ports(port_pattern)
    m.set_callback(mididump_callback)
    return m

cdef class MidiOut_slower(MidiBase):
    cdef RtMidiOut* thisptr
    def __cinit__(self):
        self.thisptr = new RtMidiOut(string(<char*>"rtmidiout"))
    def __init__(self):
        pass
    def __dealloc__(self):
        del self.thisptr
    cdef RtMidi* baseptr(self):
        return self.thisptr
    cpdef send_message(self, message):
        cdef vector[unsigned char]* message_vector = new vector[unsigned char]()
        for byte in message:
            message_vector.push_back(byte)
        self.thisptr.sendMessage(message_vector)
        del message_vector
    cpdef send_cc(self, int channel, int cc, int value):
        cdef vector[unsigned char]* m = new vector[unsigned char]()
        m.push_back(DCC | channel)
        m.push_back(cc)
        m.push_back(value)
        self.thisptr.sendMessage(m)
    cpdef send_messages(self, int messagetype, channels, values1, values2):
        """
        send multiple messages of the same type at once

        messagetype: 
            NOTEON     144
            CC         176
            NOTEOFF    128
            PROGCHANGE 192
            PITCHWHEEL 224

        channels: a sequence of integers defining the channel, or only one int if the
        channel is the same for all messages
        values1: the notenumbers or control numbers
        values2: the velocities or control values
        """
        cdef int i, channel
        cdef vector[unsigned char]* m
        cdef unsigned char v0
        if isinstance(channels, int):
            channel = channels
            v0 = messagetype | channel
        else:
            raise ValueError("multiple channels in a function call not implemented yet")
        if isinstance(values1, list):
            for i in range(len(<list>values1)):
                m = new vector[unsigned char]()
                m.push_back( v0 )
                m.push_back(<int>(<list>values1)[i])
                m.push_back(<int>(<list>values2)[i])
                self.thisptr.sendMessage(m)
                del m
        return None            
    cpdef send_noteon(self, int channel, int midinote, int velocity):
        cdef vector[unsigned char]* message_vector = new vector[unsigned char]()
        message_vector.push_back( DNOTEON|channel )
        message_vector.push_back( midinote )
        message_vector.push_back( velocity )
        self.thisptr.sendMessage(message_vector)
    cpdef send_noteon_many(self, channels, notes, vels):
        cdef int i
        cdef vector[unsigned char]* m
        if isinstance(notes, list):
            for i in range(len(<list>notes)):
                m = new vector[unsigned char]()
                m.push_back( DNOTEON |<unsigned char>(<list>channels)[i])
                m.push_back(<unsigned char>(<list>notes)[i])
                m.push_back(<unsigned char>(<list>vels)[i])
                self.thisptr.sendMessage(m)
                del m
    cpdef send_noteoff(self, unsigned char channel, unsigned char midinote):
        cdef vector[unsigned char]* m = new vector[unsigned char]()
        m.push_back(DNOTEOFF|channel)
        m.push_back(midinote)
        m.push_back(0)
        self.thisptr.sendMessage(m)
        del m
    cpdef send_noteoff_many(self, channels, notes):
        cdef int i, channel, v0
        cdef vector[unsigned char]* m
        if isinstance(channels, int):
            v0 = DNOTEOFF | <int>channels
            if isinstance(notes, list):
                for i in range(len(<list>notes)):
                    m = new vector[unsigned char]()
                    m.push_back( v0 )
                    m.push_back(<int>(<list>notes)[i])
                    m.push_back(0)
                    self.thisptr.sendMessage(m)
                    del m
            else:
                raise NotImplemented("only lists implemented right now")
        else:
            raise NotImplemented("no multiple channels implemented right now")
    
cdef class MidiOut(MidiBase):
    cdef RtMidiOut* thisptr
    cdef vector[unsigned char]* msg3
    cdef int msg3_locked
    def __cinit__(self):
        self.thisptr = new RtMidiOut(string(<char*>"rtmidiout"))
        self.msg3 = new vector[unsigned char]()
        for n in range(3):
            self.msg3.push_back(0)
        self.msg3_locked = 0
    def __init__(self): pass
    def __dealloc__(self):
        del self.thisptr
        del self.msg3
    cdef RtMidi* baseptr(self):
        return self.thisptr
    def send_message(self, tuple message not None):
        """
        message is a tuple of bytes. this sends raw midi messages
        """
        self.send_raw(message[0], message[1], message[2])

    cdef inline void send_raw(self, unsigned char b0, unsigned char b1, unsigned char b2):
        cdef vector[unsigned char]* v
        if self.msg3_locked:
            v = new vector[unsigned char](3)
            v[0][0] = b0
            v[0][1] = b1
            v[0][2] = b2
            self.thisptr.sendMessage(v)
            del v
        else:
            self.msg3_locked = 1
            v = self.msg3
            v[0][0] = b0
            v[0][1] = b1
            v[0][2] = b2
            self.thisptr.sendMessage(v)
            self.msg3_locked = 0
    cpdef send_cc(self, unsigned char channel, unsigned char cc, unsigned char value):
        """
        channel -> 0-15
        """
        self.send_raw(DCC | channel, cc, value)
    cpdef send_messages(self, int messagetype, messages):
        """
        messagetype: 
            NOTEON     144
            CC         176
            NOTEOFF    128
            PROGCHANGE 192
            PITCHWHEEL 224
        channels: a list of channels
        messages: a list of tuples of the form (channel, value1, value2), or a numpy 2D array with 3 columns and n rows
        where channel is an int between 0-15, value1 is the midinote or ccnumber, etc, and value2 is the value of the message (velocity, control value, etc)

        Example
        -------

        # send multiple noteoffs as noteon with velocity 0 for hosts which do not implement the noteoff message

        m = MidiOut()
        m.open_port()
        messages = [(0, i, 0) for i in range(127)]
        m.send_messages(144, messages)
        """
        cdef int i
        cdef vector[unsigned char]* m = new vector[unsigned char](3)
        cdef tuple tuprow
        if isinstance(messages, list):
            for tuprow in <list>messages:
                m[0][0], m[0][1], m[0][2] = tuprow
                self.thisptr.sendMessage(m)
        else:
            del m
            raise TypeError("messages should be a list of tuples. other containers (numpy arrays) are still not supported")
        del m
        return None            
    cpdef send_noteon(self, unsigned char channel, unsigned char midinote, unsigned char velocity):
        """
        NB: channel -> 0.15
        """
        self.send_raw(DNOTEON|channel, midinote, velocity)
    cpdef send_noteon_many(self, channels, notes, vels):
        """
        channels, notes and vels are sequences of integers.
        """
        cdef int i
        cdef vector[unsigned char]* m = new vector[unsigned char](3)
        if isinstance(notes, list):
            for i in range(len(<list>notes)):
                m[0][0] = DNOTEON |<unsigned char>(<list>channels)[i]
                m[0][1] = <unsigned char>(<list>notes)[i]
                m[0][2] = <unsigned char>(<list>vels)[i]
                self.thisptr.sendMessage(m)
        else:
            del m
            raise NotImplemented("channels, notes and vels should be lists. other containers are not yet implemented")
        del m
    cpdef send_noteoff(self, unsigned char channel, unsigned char midinote):
        """
        NB: channel -> 0-15
        """
        self.send_raw(DNOTEOFF|channel, midinote, 0)
    cpdef send_noteoff_many(self, channels, notes):
        """
        channels: a list of channels, or a single integer channel
        notes:    a list of midinotes to be released

        NB: channel -> 0-15
        """
        cdef int i, channel, v0
        cdef vector[unsigned char]* m = new vector[unsigned char](3)
        m[0][2] = 0
        if isinstance(channels, int):
            v0 = DNOTEOFF | <unsigned char>channels
            if isinstance(notes, list):
                for i in range(len(<list>notes)):
                    m[0][0] = v0
                    m[0][1] = <unsigned char>(<list>notes)[i]
                    self.thisptr.sendMessage(m)       
            else:
                del m
                raise NotImplemented("only lists implemented right now")
        elif isinstance(channels, list):
            for i in range(len(<list>notes)):
                m[0][0] = DNOTEOFF | <unsigned char>(<list>channels)[i]
                m[0][1] = <unsigned char>(<list>notes)[i]
                self.thisptr.sendMessage(m)       
        del m
        return None
