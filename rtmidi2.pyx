#cython: boundscheck=False
#cython: embedsignature=True
#cython: checknone=False

### cython imports
from libcpp.string cimport string
from libcpp.vector cimport vector
from cython.operator cimport dereference as deref, preincrement as inc 

### definitions
cdef extern from "Python.h":
    void PyEval_InitThreads()
from libc.stdlib cimport malloc, free

### python imports
import inspect

# Init Python threads and GIL, because RtMidi calls Python from native threads.
# See http://permalink.gmane.org/gmane.comp.python.cython.user/5837
PyEval_InitThreads()

### constants
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

cdef list _notenames = ["C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "Bb", "B", "C"]
cdef dict MSGTYPES = {
    NOTEON:     'NOTEON',
    NOTEOFF:    'NOTEOFF',
    CC:         'CC',
    PITCHWHEEL: 'PITCHWHEEL',
    PROGCHANGE: 'PROGCHANGE'
}

### C++ interface
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
        """
        port: an integer or a string
        
        The string can contain a pattern, in which case it will be matched against
        the existing ports and the first match will be used
        
        Example
        =======
        
        from rtmidi2 import MidiIn
        
        m = MidiIn().open_port("BCF*")
        """
        if isinstance(port, int):
            if port > len(self.ports) - 1:
                raise ValueError("port number out of range")
            port_number = port
        else:
            ports = self.ports
            if port in ports:
                port_number = self.ports.index(port)
            else:
                match = self.ports_patching(port)
                if match:
                    return self.open_port(match[0])
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

        """
        import fnmatch
        ports = self.ports
        return [i for i, port in enumerate(ports) if fnmatch.fnmatch(port, pattern)]

### callbacks
cdef void midi_in_callback(double time_stamp, vector[unsigned char]* message_vector, void* py_callback) with gil:
    message = [message_vector.at(i) for i in range(message_vector.size())]
    (<object>py_callback)(message, time_stamp)

cdef void midi_in_callback_with_src(double time_stamp, vector[unsigned char]* message_vector, void* pythontuple) with gil:
    message = [message_vector.at(i) for i in range(message_vector.size())]
    portname, callback = <tuple>pythontuple
    callback(portname, message, time_stamp)

cdef class MidiIn(MidiBase):
    cdef RtMidiIn* thisptr
    cdef object py_callback
    def __cinit__(self, clientname="RTMIDI-IN", queuesize=100):
        self.thisptr = new RtMidiIn(string(<char*>clientname), queuesize)
        self.py_callback = None
    def __init__(self, clientname="RTMIDI-IN", queuesize=100):
        """
        It is NOT necessary to give the client a name.
        queuesize: the size of the queue in bytes.

        Example
        -------

        from rtmidi2 import MidiIn, NOTEON, CC, splitchannel
        m_in = MidiIn()
        m_in.open_port()    # will get messages from the default port

        def callback(msg, timestamp):
            msgtype, channel = splitchannel(msg[0])
            if msgtype == NOTEON:
                note, velocity = msg[1], msg[2]
                print "noteon", note, velocity
            elif msgtype == CC:
                cc, value = msg[1:]
                print "control change", cc, value

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
        """
        Don't react to these messages. This avoids having to make your callback
        aware of these and avoids congestion where your device acts as a midiclock
        but your not interested in that. 
        """
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
    cdef list qualified_callbacks
    cdef list openports
    cdef dict hascallback
    def __cinit__(self, clientname="RTMIDI-IN", queuesize=100):
        self.inspector = new RtMidiIn(string(<char*>"RTMIDI-INSPECTOR"), queuesize)
        self.ptrs = new vector[RtMidiIn *]()
        self.py_callback = None
        self.qualified_callbacks = []
    def __init__ (self, clientname="RTMIDI-IN", queuesize=100):
        """
        This class implements the capability to listen to multiple inputs at once
        A callback needs to be defined, as in MidiIn, which will be called if any
        of the devices receives any input. 

        Your callback can be of two forms:
        
        def callback(msg, time):
            msgtype, channel = splitchannel(msg[0])
            print msgtype, msg[1], msg[2]
            
        def callback_with_source(src, msg, time):
            print "message generated from midi-device: ", src
            msgtype, channel = splitchannel(msg[0])
            print msgtype, msg[1], msg[2]
            
        midiin = MidiInMulti().open_ports("*")
        midiin.callback = callback_with_source   # your callback will be called according to its signature
        
        If you need to know the port number of the device initiating the message instead of the device name,
        use:
        
        midiin.set_callback(callback_with_source, src_as_string=False)
            
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
    def get_port_name(self, int i):
        return self.inspector.getPortName(i).c_str()
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
    cpdef open_port(self, unsigned int port):
        """
        Low level interface to opening ports by index. Use open_ports to use a more
        confortable API.
        
        Example
        =======
        
        midiin.open_port(0)  # open the default port
        
        # open all ports
        for i in len(midiin.ports):
            midiin.open_port(i)
            
        SEE ALSO: open_ports
        """
        if port >= self.inspector.getPortCount():
            raise ValueError("Port out of range")
        if port in self.openports:
            raise ValueError("Port already open!")
        cdef RtMidiIn* newport = new RtMidiIn(string(<char*>self.clientname), self.queuesize)
        portname = self.inspector.getPortName(port).c_str()
        newport.openPort(port)
        self.ptrs.push_back(newport)
        self.openports.append(port)
        return self
    def open_ports(self, *patterns):
        """
        You can specify multiple patterns. Of course a pattern can be also be an exact match
        
        midiin.open_ports("BCF2000", "Korg*") # dont care to specify the full name of the Korg device

        Example
        -------

        # Transpose all notes received one octave up, send them to a virtual port named "OUT"
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
        for pattern in patterns:
            for port in self.ports_matching(pattern):
                self.open_port(port)
        return self
        
    cpdef close_ports(self):
        """closes all ports and deactivates any callback.
        NB: closing of individual ports is not implemented.
        """
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
            cdef RtMidiIn* ptr
            try:
                # numargs = callback.__code__.co_argcount
                numargs = _func_get_numargs(callback)
                if numargs == 3:
                    self._set_qualified_callback(callback)
                    return
            except AttributeError:
                # this is a builtin function? Anyway, we assume it is a 2 arg callback
                pass
            self.py_callback = callback
            for i in range(self.ptrs.size()):
                ptr = self.ptrs.at(i)
                port = self.openports[i]
                if self.hascallback.get(port, False):
                    ptr.cancelCallback()
                if callback is not None:
                    ptr.setCallback(midi_in_callback, <void*>callback)
                    self.hascallback[port] = True

    def set_callback(self, callback, src_as_string=True):
        """
        This is the same as
        
        midiin.callback = mycallback
        
        But lets you specify if you want your callback to be called as callback(msg, time) or callback(src, msg, time)
        
        callback (function) : your callback. 
        src_as_string (bool): This only applies for the case where your callback is (src, msg, time)
                              In this case, if src_as_string is True, the source is the string representing the source
                              Otherwise, it is the port number.
                              
        Example
        =======
        
        def callback_with_source(src, msg, time):
            print "message generated from midi-device: ", src
            msgtype, channel = splitchannel(msg[0])
            print msgtype, msg[1], msg[2]
            
        midiin = MidiInMulti().open_ports("*")
        midiin.set_callback( callback_with_source )   # your callback will be called according to its signature
        """
        numargs = _func_get_numargs(callback)
        if numargs == 2:
            self.callback = callback
        elif numargs == 3:
            self._seq_qualified_callback(callback, src_as_string)
        else:
            raise ValueError("Your callback has to have either the signature (msg, time) or the signature (source, msg, time)")
        return self
    
    def set_qualified_callback(self, *args, **kws):
        raise TypeError("USE set_callback with a function with signature (src, msg, time)")
    
    def _set_qualified_callback(self, callback, src_as_string=True):
        """
        this callback will be called with src, msg, time

        where:
            src  is the integer identifying the in-port or the string name if src_as_string is True. The string is: midiin.ports[src]
            msg  is a 3 byte midi message
            time is the time identifier of the message

        """
        cdef RtMidiIn* ptr
        self.py_callback = callback
        self.qualified_callbacks = []
        for i in range(self.ptrs.size()):
            ptr = self.ptrs.at(i)
            port = self.openports[i]
            if self.hascallback.get(port, False):
                ptr.cancelCallback()
            if callback is not None:
                if not src_as_string:
                    tup = (port, callback)
                else:
                    tup = (self.inspector.getPortName(i).c_str(), callback)
                self.qualified_callbacks.append(tup)
                ptr.setCallback(midi_in_callback_with_src, <void*>tup)
                self.hascallback[port] = True    
    
    def get_message(self, int gettime=1):
        raise NotImplemented("The blocking interface is not implemented for multiple inputs. Use the callback system")

cpdef tuple splitchannel(int b):
    """
    split the messagetype and the channel as returned by get_message

    msg = midiin.get_message()
    msgtype, channel = splitchannel(msg[0])
    
    SEE ALSO: msgtype2str
    """
    return b & 0xF0, b & 0x0F

def _func_get_numargs(func):
    spec = inspect.getargspec(func)
    numargs = sum(1 for a in spec.args if a is not "self")
    return numargs

def msgtype2str(msgtype):
    """
    convert the message-type as returned by splitchannel(msg[0])[0] to a readable string
    
    SEE ALSO: splitchannel
    """
    return MSGTYPES.get(msgtype, 'UNKNOWN')
    
def midi2note(midinote):
    """
    convert a midinote to the string representation of the note
    
    Example
    =======
    
    >>> midi2note(60)
    "C4"
    """
    octave = int(midinote / 12) - 1
    pitchindex = midinote % 12
    return "%s%d" % (_notenames[pitchindex], octave)

def mididump_callback(src, msg, t):
    """
    use this function as your callback to dump all received messages
    """
    msgt, ch = splitchannel(msg[0])
    msgtstr = msgtype2str(msgt)
    val1 = int(msg[1])
    val2 = int(msg[2])
    srcstr = src.ljust(20)[:20]
    if msgt == CC:
        print "%s | CC | ch %02d | cc %03d | val %03d" % (srcstr, ch, val1, val2)
    elif msgt == NOTEON:
        notename = midi2note(val1)
        print "%s | NOTEON | ch %d | note %s (%03d) | vel %d" % (srcstr, ch, notename.ljust(3), val1, val2)
    else:
        print "%s | %s | ch %d | val1 %d | val2 %d" % (srcstr, msgtstr, ch, val1, val2)

def mididump(port_pattern="*"):
    """
    listen to all ports matching pattern and print the received messages
    """
    m = MidiInMulti().open_ports(port_pattern)
    m.set_callback(mididump_callback, src_as_string=True)
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
        cdef channel
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
        cdef channel, v0
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
        cdef channel, v0
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
