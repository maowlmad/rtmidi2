import distutils
import sys

if not '--from-cpp' in sys.argv:
    from Cython.Distutils import build_ext
    module_source = 'rtmidi2.pyx'
else:
    from distutils.command.build_ext import build_ext
    sys.argv.remove('--from-cpp')    
    module_source = 'rtmidi2.cpp'

extension_args = {}

if sys.platform.startswith('linux'):
    extension_args = dict(
        define_macros=[('__LINUX_ALSASEQ__', None)],
        libraries=['asound', 'pthread']
    )

if sys.platform == 'darwin':
    extension_args = dict(
        define_macros=[('__MACOSX_CORE__', None)],
        extra_compile_args=['-frtti'],
        extra_link_args=[
            '-framework', 'CoreMidi',
            '-framework', 'CoreAudio',
            '-framework', 'CoreFoundation'
        ]
    )

if sys.platform == 'win32':
    extension_args = dict(
        define_macros=[('__WINDOWS_MM__', None)],
        libraries=['winmm']
    )

rtmidi_module = distutils.extension.Extension(
    'rtmidi2',
    [module_source, 'RtMidi/RtMidi.cpp'],
    language='c++',
    **extension_args
)

distutils.core.setup(
    name='rtmidi2',
    version='0.3.1',
    description='Python wrapper for RtMidi written in Cython. Allows sending raw messages, multi-port input and sending multiple messages in one call.',
    author='originally by Guido Lorenz, modified by Eduardo Moguillansky',
    author_email='code@superquadratic.net',
    url="https://github.com/gesellkammer/rtmidi2",
    cmdclass={'build_ext': build_ext},
    ext_modules=[rtmidi_module],
    license='MIT',
    classifiers=[
        'Development Status :: 4 - Beta',
        'Programming Language :: Cython',
        'Topic :: Multimedia :: Sound/Audio :: MIDI',
        'License :: OSI Approved :: MIT License'
    ]
)
