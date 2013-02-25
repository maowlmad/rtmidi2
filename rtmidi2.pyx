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

DEF NOTEON=144
DEF CC=176
DEF NOTEOFF=128
DEF PROGCHANGE=192
DEF PITCHWHEEL=224

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
    def open_virtual_port(self, port_name):
        self.baseptr().openVirtualPort(string(<char*>port_name))
    property ports:
        def __get__(self):
            return [self.baseptr().getPortName(i).c_str() for i in range(self.baseptr().getPortCount())]
    def close_port(self):
        self.baseptr().closePort()
    def ports_matching(self, pattern):
        import fnmatch
        ports = self.ports
        return [i for i, port in enumerate(ports) if fnmatch.fnmatch(port, pattern)]

cdef void midi_in_callback(double time_stamp, vector[unsigned char]* message_vector, void* py_callback) with gil:
    message = [message_vector.at(i) for i in range(message_vector.size())]
    (<object>py_callback)(message, time_stamp)

cdef class MidiIn(MidiBase):
    cdef RtMidiIn* thisptr
    cdef object py_callback
    def __cinit__(self, client_name="RtMidi Input Client", queue_size_limit=100):
        self.thisptr = new RtMidiIn(string(<char*>client_name), queue_size_limit)
        self.py_callback = None
    def __dealloc__(self):
        del self.thisptr
    cdef RtMidi* baseptr(self):
        return self.thisptr
    property callback:
        def __get__(self):
            return self.py_callback
        def __set__(self, callback):
            if self.py_callback is not None:
                self.thisptr.cancelCallback()
            self.py_callback = callback
            if self.py_callback is not None:
                self.thisptr.setCallback(midi_in_callback, <void*>self.py_callback)
    def ignore_types(self, midi_sysex=True, midi_time=True, midi_sense=True):
        self.thisptr.ignoreTypes(midi_sysex, midi_time, midi_sense)
    def get_message(self):
        cdef vector[unsigned char]* message_vector = new vector[unsigned char]()
        delta_time = self.thisptr.getMessage(message_vector)
        if not message_vector.empty():
            message = [message_vector.at(i) for i in range(message_vector.size())]
            return message, delta_time
        else:
            return None, None

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
        m.push_back(CC | channel)
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
        message_vector.push_back( NOTEON|channel )
        message_vector.push_back( midinote )
        message_vector.push_back( velocity )
        self.thisptr.sendMessage(message_vector)
    cpdef send_noteon_many(self, channels, notes, vels):
        cdef int i
        cdef vector[unsigned char]* m
        if isinstance(notes, list):
            for i in range(len(<list>notes)):
                m = new vector[unsigned char]()
                m.push_back( NOTEON |<unsigned char>(<list>channels)[i])
                m.push_back(<unsigned char>(<list>notes)[i])
                m.push_back(<unsigned char>(<list>vels)[i])
                self.thisptr.sendMessage(m)
                del m
    cpdef send_noteoff(self, unsigned char channel, unsigned char midinote):
        cdef vector[unsigned char]* m = new vector[unsigned char]()
        m.push_back(NOTEOFF|channel)
        m.push_back(midinote)
        m.push_back(0)
        self.thisptr.sendMessage(m)
        del m
    cpdef send_noteoff_many(self, channels, notes):
        cdef int i, channel, v0
        cdef vector[unsigned char]* m
        if isinstance(channels, int):
            v0 = NOTEOFF | <int>channels
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
        self.send_raw(CC | channel, cc, value)
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
        self.send_raw(NOTEON|channel, midinote, velocity)
    cpdef send_noteon_many(self, channels, notes, vels):
        """
        channels, notes and vels are sequences of integers.
        """
        cdef int i
        cdef vector[unsigned char]* m = new vector[unsigned char](3)
        if isinstance(notes, list):
            for i in range(len(<list>notes)):
                m[0][0] = NOTEON |<unsigned char>(<list>channels)[i]
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
        self.send_raw(NOTEOFF|channel, midinote, 0)
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
            v0 = NOTEOFF | <unsigned char>channels
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
                m[0][0] = NOTEOFF | <unsigned char>(<list>channels)[i]
                m[0][1] = <unsigned char>(<list>notes)[i]
                self.thisptr.sendMessage(m)       
        del m
        return None
