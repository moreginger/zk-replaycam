#!/usr/bin/env python3
"""Run replaycam.lua offline against a stubbed game (see scripts/harness.lua).

    run-harness.py [raid|bombers|recall] [--crowd N] [--log infolog.txt] [--verbose]

Needs the Lua 5.4 shared library (liblua5.4), loaded through ctypes. --log writes the widget's
output as an infolog that generate-stats.py can read.
"""

import argparse
import ctypes
import ctypes.util
import os
import sys

here = os.path.dirname(os.path.abspath(__file__))
parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
parser.add_argument('scenario', nargs='?', default='raid', choices=['raid', 'bombers', 'recall'],
                    help='recall turns the raid around halfway, so no scene should fire')
parser.add_argument('--crowd', type=int, default=0, help='extra units milling about, to measure cost')
parser.add_argument('--log', help='write the widget output here as an infolog')
parser.add_argument('--verbose', action='store_true', help='print everything the widget logs')
parser.add_argument('--widget', default=os.path.join(here, '..', 'replaycam.lua'))
args = parser.parse_args()

os.environ.update(WIDGET=args.widget, SCENARIO=args.scenario, CROWD=str(args.crowd))
if args.log:
    os.environ['LOG'] = args.log
if args.verbose:
    os.environ['VERBOSE'] = '1'

lua = ctypes.CDLL(ctypes.util.find_library('lua5.4') or 'liblua5.4.so.0')
lua.luaL_newstate.restype = ctypes.c_void_p
lua.luaL_openlibs.argtypes = [ctypes.c_void_p]
lua.luaL_loadfilex.argtypes = [ctypes.c_void_p, ctypes.c_char_p, ctypes.c_char_p]
lua.lua_pcallk.argtypes = [ctypes.c_void_p, ctypes.c_int, ctypes.c_int, ctypes.c_int, ctypes.c_void_p, ctypes.c_void_p]
lua.lua_tolstring.restype = ctypes.c_char_p
lua.lua_tolstring.argtypes = [ctypes.c_void_p, ctypes.c_int, ctypes.c_void_p]

state = lua.luaL_newstate()
lua.luaL_openlibs(state)
harness = os.path.join(here, 'harness.lua').encode()
if lua.luaL_loadfilex(state, harness, None) or lua.lua_pcallk(state, 0, 0, 0, None, None):
    sys.exit('FAILED: ' + lua.lua_tolstring(state, -1, None).decode())
