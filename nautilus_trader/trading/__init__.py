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
"""
The `trading` subpackage groups all trading domain specific components and tooling.

This is a top-level package where the majority of users will interface with the
framework. Custom trading strategies can be implemented by inheriting from the
`Strategy` base class.

"""

from nautilus_trader.trading.controller import Controller
from nautilus_trader.trading.strategy import Strategy
from nautilus_trader.trading.trader import Trader


__all__ = [
    "Controller",
    "Strategy",
    "Trader",
]
