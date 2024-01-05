# -------------------------------------------------------------------------------------------------
#  Copyright (C) 2015-2024 Nautech Systems Pty Ltd. All rights reserved.
#  https://nautechsystems.io
#
#  Licensed under the GNU Lesser General Public License Version 3.0 (the "License");
#  You may not use this file except in compliance with the License.
#  You may obtain a copy of the License at https://www.gnu.org/licenses/lgpl-3.0.en.html
#
#  Unless required by applicable law or agreed to in writing, software
#  distributed under the License is distributed on an "AS IS" BASIS,
#  WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
#  See the License for the specific language governing permissions and
#  limitations under the License.
# -------------------------------------------------------------------------------------------------

from typing import Callable

from libc.stdint cimport uint64_t

from nautilus_trader.common.clock cimport Clock
from nautilus_trader.common.logging cimport Logger
from nautilus_trader.core.rust.common cimport LogColor
from nautilus_trader.core.rust.common cimport LogLevel
from nautilus_trader.core.uuid cimport UUID4
from nautilus_trader.model.identifiers cimport TraderId


cpdef void init_tracing()
cpdef void init_logging(
    TraderId trader_id,
    UUID4 instance_id,
    str config_spec,
    str file_directory,
    str file_name,
    str file_format,
)

cpdef LogColor log_color_from_str(str value)
cpdef str log_color_to_str(LogColor value)

cpdef LogLevel log_level_from_str(str value)
cpdef str log_level_to_str(LogLevel value)


cdef str RECV
cdef str SENT
cdef str CMD
cdef str EVT
cdef str DOC
cdef str RPT
cdef str REQ
cdef str RES


cdef class Logger:
    cdef Clock _clock

    cdef TraderId _trader_id
    cdef UUID4 _instance_id
    cdef str _machine_id
    cdef bint _is_colored
    cdef bint _is_bypassed

    cdef void log(
        self,
        LogLevel level,
        LogColor color,
        const char* component_cstr,
        str message,
    )

    cpdef void change_clock(self, Clock clock)
    cpdef void flush(self)


cdef class LoggerAdapter:
    cdef Logger _logger
    cdef str _component
    cdef const char* _component_cstr
    cdef bint _is_colored
    cdef bint _is_bypassed

    cpdef Logger get_logger(self)
    cpdef void debug(self, str message, LogColor color=*, dict annotations=*)
    cpdef void info(self, str message, LogColor color=*, dict annotations=*)
    cpdef void warning(self, str message, LogColor color=*, dict annotations=*)
    cpdef void error(self, str message, LogColor color=*, dict annotations=*)
    cpdef void exception(self, str message, ex, dict annotations=*)


cpdef void nautilus_header(LoggerAdapter logger)
cpdef void log_memory(LoggerAdapter logger)
