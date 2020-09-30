# -------------------------------------------------------------------------------------------------
#  Copyright (C) 2015-2020 Nautech Systems Pty Ltd. All rights reserved.
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

import queue
import threading

from nautilus_trader.common.account cimport Account
from nautilus_trader.common.clock cimport Clock
from nautilus_trader.common.generators cimport PositionIdGenerator
from nautilus_trader.common.logging cimport CMD
from nautilus_trader.common.logging cimport EVT
from nautilus_trader.common.logging cimport Logger
from nautilus_trader.common.logging cimport LoggerAdapter
from nautilus_trader.common.logging cimport RECV
from nautilus_trader.common.portfolio cimport Portfolio
from nautilus_trader.common.uuid cimport UUIDFactory
from nautilus_trader.core.correctness cimport Condition
from nautilus_trader.core.decimal cimport Decimal64
from nautilus_trader.core.fsm cimport InvalidStateTrigger
from nautilus_trader.core.message cimport Message
from nautilus_trader.core.message cimport MessageType
from nautilus_trader.execution.database cimport ExecutionDatabase
from nautilus_trader.model.commands cimport AccountInquiry
from nautilus_trader.model.commands cimport CancelOrder
from nautilus_trader.model.commands cimport Command
from nautilus_trader.model.commands cimport ModifyOrder
from nautilus_trader.model.commands cimport SubmitBracketOrder
from nautilus_trader.model.commands cimport SubmitOrder
from nautilus_trader.model.events cimport AccountState
from nautilus_trader.model.events cimport Event
from nautilus_trader.model.events cimport OrderCancelReject
from nautilus_trader.model.events cimport OrderDenied
from nautilus_trader.model.events cimport OrderEvent
from nautilus_trader.model.events cimport OrderFilled
from nautilus_trader.model.events cimport OrderInvalid
from nautilus_trader.model.events cimport PositionClosed
from nautilus_trader.model.events cimport PositionEvent
from nautilus_trader.model.events cimport PositionModified
from nautilus_trader.model.events cimport PositionOpened
from nautilus_trader.model.identifiers cimport AccountId
from nautilus_trader.model.identifiers cimport PositionId
from nautilus_trader.model.identifiers cimport StrategyId
from nautilus_trader.model.identifiers cimport TraderId
from nautilus_trader.model.objects cimport Quantity
from nautilus_trader.model.order cimport Order
from nautilus_trader.trading.strategy cimport TradingStrategy


cdef class ExecutionEngine:
    """
    Provides a high performance execution engine.
    """

    def __init__(
            self,
            TraderId trader_id not None,
            AccountId account_id not None,
            ExecutionDatabase database not None,
            OMSType oms_type,
            Portfolio portfolio not None,
            Clock clock not None,
            UUIDFactory uuid_factory not None,
            Logger logger not None
    ):
        """
        Initialize a new instance of the ExecutionEngine class.

        Parameters
        ----------
        trader_id : TraderId
            The trader identifier for the engine.
        account_id : AccountId
            The account identifier for the engine.
        database : ExecutionDatabase
            The execution database for the engine.
        oms_type : OMSType
            The order management type for the engine.
        portfolio : Portfolio
            The portfolio for the engine.
        clock : Clock
            The clock for the engine.
        uuid_factory : UUIDFactory
            The uuid_factory for the engine.
        logger : Logger
            The logger for the engine.

        Raises
        ------
        ValueError
            If trader_id is not equal to the database.trader_id.
        ValueError
            If oms_type is UNDEFINED.

        """
        Condition.equal(trader_id, database.trader_id, "trader_id", "database.trader_id")
        Condition.not_equal(oms_type, OMSType.UNDEFINED, "oms_type", "UNDEFINED")

        self._clock = clock
        self._uuid_factory = uuid_factory
        self._log = LoggerAdapter("ExecEngine", logger)
        self._oms_type = oms_type
        self._pos_id_generator = PositionIdGenerator(trader_id.tag)
        self._exec_client = None
        self._registered_strategies = {}    # type: {StrategyId, TradingStrategy}

        self.trader_id = trader_id
        self.account_id = account_id
        self.database = database
        self.account = self.database.get_account(account_id)
        self.portfolio = portfolio

        # Set symbol position counts
        symbol_counts = self.database.get_symbol_position_counts()
        for symbol, count in symbol_counts.items():
            self._pos_id_generator.set_count(symbol, count)

        self.command_count = 0
        self.event_count = 0

# -- REGISTRATIONS ---------------------------------------------------------------------------------

    cpdef void register_client(self, ExecutionClient exec_client) except *:
        """
        Register the given execution client with the execution engine.

        Parameters
        ----------
        exec_client : ExecutionClient
            The execution client to register.

        """
        Condition.not_none(exec_client, "exec_client")

        self._exec_client = exec_client
        self._log.info("Registered execution client.")

    cpdef void register_strategy(self, TradingStrategy strategy) except *:
        """
        Register the given strategy with the execution engine.

        Parameters
        ----------
        strategy : TradingStrategy
            The strategy to register.

        Raises
        ------
        ValueError
            If strategy is already registered with the execution engine.

        """
        Condition.not_none(strategy, "strategy")
        Condition.not_in(strategy.id, self._registered_strategies, "strategy.id", "registered_strategies")

        strategy.register_execution_engine(self)
        self._registered_strategies[strategy.id] = strategy
        self._log.info(f"Registered strategy {strategy}.")

    cpdef void deregister_strategy(self, TradingStrategy strategy) except *:
        """
        Deregister the given strategy with the execution engine.

        Parameters
        ----------
        strategy : TradingStrategy
            The strategy to deregister.

        Raises
        ------
        ValueError
            If strategy is not registered with the execution engine.

        """
        Condition.not_none(strategy, "strategy")
        Condition.is_in(strategy.id, self._registered_strategies, "strategy.id", "registered_strategies")

        del self._registered_strategies[strategy.id]
        self._log.info(f"De-registered strategy {strategy}.")

    cpdef list registered_strategies(self):
        """
        Return a list of strategy_ids registered with the execution engine.

        Returns
        -------
        List[StrategyId]

        """
        return list(self._registered_strategies.keys())

# -- COMMANDS --------------------------------------------------------------------------------------

    cpdef void execute(self, Command command) except *:
        """
        Execute the given command.

        Parameters
        ----------
        command : Command
            The command to execute.

        """
        Condition.not_none(command, "command")

        self._execute_command(command)

    cpdef void process(self, Event event) except *:
        """
        Process the given event.

        Parameters
        ----------
        event : Event
            The event to process.

        """
        Condition.not_none(event, "event")

        self._handle_event(event)

    cpdef void check_residuals(self) except *:
        """
        Check for residual working orders or open positions.
        """
        self.database.check_residuals()

    cpdef void reset(self) except *:
        """
        Reset the execution engine by clearing all stateful values.
        """
        self.database.reset()
        self._pos_id_generator.reset()

        self.command_count = 0
        self.event_count = 0

# -- QUERIES ---------------------------------------------------------------------------------------

    cdef inline Decimal64 _sum_net_position(self, Symbol symbol, StrategyId strategy_id):
        cdef dict positions = self.database.get_positions_open(symbol, strategy_id)
        cdef Decimal64 net_quantity = Decimal64()

        cdef Position position
        for position in positions:
            if position.is_long():
                net_quantity += position.quantity
            elif position.is_short():
                net_quantity -= position.quantity

        return net_quantity

    cpdef bint is_net_long(self, Symbol symbol, StrategyId strategy_id=None) except *:
        """
        Return a value indicating whether the execution engine is net long a
        given symbol.

        Parameters
        ----------
        symbol : Symbol
            The symbol for the query.
        strategy_id : StrategyId, optional
            The strategy identifier query filter.

        Returns
        -------
        bool

        """
        return self._sum_net_position(symbol, strategy_id) > 0

    cpdef bint is_net_short(self, Symbol symbol, StrategyId strategy_id=None) except *:
        """
        Return a value indicating whether the execution engine is net short a
        given symbol.

        Parameters
        ----------
        symbol : Symbol
            The symbol for the query.
        strategy_id : StrategyId, optional
            The strategy identifier query filter.

        Returns
        -------
        bool

        """
        return self._sum_net_position(symbol, strategy_id) < 0

    cpdef bint is_flat(self, Symbol symbol=None, StrategyId strategy_id=None) except *:
        """
        Return a value indicating whether the execution engine is flat.

        Parameters
        ----------
        symbol : Symbol, optional
            The symbol query filter.
        strategy_id : StrategyId, optional
            The strategy identifier query filter.

        Returns
        -------
        bool

        """
        return self.database.positions_open_count(symbol, strategy_id) == 0

# --------------------------------------------------------------------------------------------------

    cdef void _execute_command(self, Command command) except *:
        self._log.debug(f"{RECV}{CMD} {command}.")
        self.command_count += 1

        if isinstance(command, AccountInquiry):
            self._handle_account_inquiry(command)
        elif isinstance(command, SubmitOrder):
            self._handle_submit_order(command)
        elif isinstance(command, SubmitBracketOrder):
            self._handle_submit_bracket_order(command)
        elif isinstance(command, ModifyOrder):
            self._handle_modify_order(command)
        elif isinstance(command, CancelOrder):
            self._handle_cancel_order(command)
        else:
            self._log.error(f"Cannot handle command ({command} is unrecognized).")

    cdef void _invalidate_order(self, Order order, str reason) except *:
        # Generate event
        cdef OrderInvalid invalid = OrderInvalid(
            order.cl_ord_id,
            reason,
            self._uuid_factory.generate(),
            self._clock.utc_now())

        self._handle_event(invalid)

    cdef void _deny_order(self, Order order, str reason) except *:
        # Generate event
        cdef OrderDenied denied = OrderDenied(
            order.cl_ord_id,
            reason,
            self._uuid_factory.generate(),
            self._clock.utc_now())

        self._handle_event(denied)

    cdef void _handle_account_inquiry(self, AccountInquiry command) except *:
        self._exec_client.account_inquiry(command)

    cdef void _handle_submit_order(self, SubmitOrder command) except *:
        # Validate order identifier
        if self.database.order_exists(command.order.cl_ord_id):
            self._invalidate_order(command.order, f"cl_ord_id already exists")
            return  # Cannot submit order

        # TODO
        # if self._oms_type == OMSType.NETTING:

        if command.position_id.not_null() and not self.database.position_exists(command.position_id):
            self._invalidate_order(command.order, f"position_id does not exist")
            return  # Cannot submit order

        # Persist order
        self.database.add_order(command.order, command.position_id, command.strategy_id)

        # Submit order
        self._exec_client.submit_order(command)

    cdef void _handle_submit_bracket_order(self, SubmitBracketOrder command) except *:
        # Validate order identifiers ---------------------------------------------------------------
        if self.database.order_exists(command.bracket_order.entry.cl_ord_id):
            self._invalidate_order(command.bracket_order.entry, f"cl_ord_id already exists")
            self._invalidate_order(command.bracket_order.stop_loss, "parent cl_ord_id already exists")
            if command.bracket_order.has_take_profit:
                self._invalidate_order(command.bracket_order.take_profit, "parent cl_ord_id already exists")
            return  # Cannot submit order
        if self.database.order_exists(command.bracket_order.stop_loss.cl_ord_id):
            self._invalidate_order(command.bracket_order.entry, "OCO cl_ord_id already exists")
            self._invalidate_order(command.bracket_order.stop_loss, "cl_ord_id already exists")
            if command.bracket_order.has_take_profit:
                self._invalidate_order(command.bracket_order.take_profit, "OCO cl_ord_id already exists")
            return  # Cannot submit order
        if command.bracket_order.has_take_profit and self.database.order_exists(command.bracket_order.take_profit.cl_ord_id):
            self._invalidate_order(command.bracket_order.entry, "OCO cl_ord_id already exists")
            self._invalidate_order(command.bracket_order.stop_loss, "OCO cl_ord_id already exists")
            self._invalidate_order(command.bracket_order.take_profit, "cl_ord_id already exists")
            return  # Cannot submit order
        # ------------------------------------------------------------------------------------------

        # Persist all orders
        self.database.add_order(command.bracket_order.entry, PositionId.null(), command.strategy_id)
        self.database.add_order(command.bracket_order.stop_loss, PositionId.null(), command.strategy_id)
        if command.bracket_order.has_take_profit:
            self.database.add_order(command.bracket_order.take_profit, PositionId.null(), command.strategy_id)

        # Submit bracket order
        self._exec_client.submit_bracket_order(command)

    cdef void _handle_modify_order(self, ModifyOrder command) except *:
        self._exec_client.modify_order(command)

    cdef void _handle_cancel_order(self, CancelOrder command) except *:
        self._exec_client.cancel_order(command)

    cdef void _handle_event(self, Event event) except *:
        self._log.debug(f"{RECV}{EVT} {event}.")
        self.event_count += 1

        if isinstance(event, OrderEvent):
            if isinstance(event, OrderCancelReject):
                self._handle_order_cancel_reject(event)
            else:
                self._handle_order_event(event)
        elif isinstance(event, PositionEvent):
            self._handle_position_event(event)
        elif isinstance(event, AccountState):
            self._handle_account_event(event)
        else:
            self._log.error(f"Cannot handle event ({event} is unrecognized).")

    cdef void _handle_order_cancel_reject(self, OrderCancelReject event) except *:
        cdef StrategyId strategy_id = self.database.get_strategy_for_order(event.cl_ord_id)
        if not strategy_id:
            self._log.error(f"Cannot process event {event}, "
                            f"{strategy_id.to_string(with_class=True)} "
                            f"not found.")
            return  # Cannot process event further

        self._send_to_strategy(event, strategy_id)

    cdef void _handle_order_event(self, OrderEvent event) except *:
        cdef Order order = self.database.get_order(event.cl_ord_id)
        if not order:
            self._log.warning(f"Cannot apply event {event} to any order, "
                              f"{event.cl_ord_id.to_string(with_class=True)} "
                              f"not found in cache.")
            return  # Cannot process event further

        try:
            order.apply(event)
        except InvalidStateTrigger as ex:
            self._log.exception(ex)

        self.database.update_order(order)

        if isinstance(event, OrderFilled):
            self._handle_order_fill(event)
            return  # _handle_order_fill(event) will send to strategy (refactor)

        self._send_to_strategy(event, self.database.get_strategy_for_order(event.cl_ord_id))

    cdef void _handle_order_fill(self, OrderFilled fill) except *:
        # Get PositionId corresponding to fill
        cdef PositionId position_id = self.database.get_position_id(fill.cl_ord_id)
        # --- position_id could be None here (position not opened yet) ---

        # Get StrategyId corresponding to fill
        cdef StrategyId strategy_id = self.database.get_strategy_for_order(fill.cl_ord_id)
        if strategy_id is None:
            self._log.error(f"Cannot process event {fill}, StrategyId for "
                            f"{fill.cl_ord_id.to_string(with_class=True)} not found.")
            return  # Cannot process event further

        if fill.position_id is None:  # Exchange not assigning position_ids
            self._fill_pos_id_none(position_id, fill, strategy_id)
        else:
            self._fill_pos_id(position_id, fill, strategy_id)

    cdef void _fill_pos_id_none(self, PositionId position_id, OrderFilled fill, StrategyId strategy_id) except *:
        if position_id is None:  # No position yet
            # Generate identifier
            position_id = self._pos_id_generator.generate(fill.symbol)
            fill.set_position_id(position_id)

            # Create new position
            self._open_position(fill, strategy_id)
        else:  # Position exists
            fill.set_position_id(position_id)
            self._update_position(fill, strategy_id)

    cdef void _fill_pos_id(self, PositionId position_id, OrderFilled fill, StrategyId strategy_id) except *:
        if position_id is None:  # No position
            self._open_position(fill, strategy_id)
        else:
            self._update_position(fill, strategy_id)

    cdef void _open_position(self, OrderFilled fill, StrategyId strategy_id) except *:
        cdef Position position = Position(fill)
        self.database.add_position(position, strategy_id)
        #self.database.index_position_id(position_id, fill.cl_ord_id, strategy_id)

        self._send_to_strategy(fill, strategy_id)
        self.process(self._pos_opened_event(position, fill, strategy_id))

    cdef void _update_position(self, OrderFilled fill, StrategyId strategy_id) except *:
        cdef Position position = self.database.get_position(fill.position_id)

        if position is None:
            self._log.error(f"Cannot update position for "
                            f"{fill.position_id.to_string(with_class=True)} "
                            f"(no position found in cache).")
            return

        position.apply(fill)
        self.database.update_position(position)

        cdef PositionEvent position_event
        if position.is_closed():
            position_event = self._pos_closed_event(position, fill, strategy_id)
        else:
            position_event = self._pos_modified_event(position, fill, strategy_id)

        self._send_to_strategy(fill, strategy_id)
        self.process(position_event)

    cdef void _handle_position_event(self, PositionEvent event) except *:
        self.portfolio.update(event)
        self._send_to_strategy(event, event.strategy_id)

    cdef void _handle_account_event(self, AccountState event) except *:
        cdef Account account = self.database.get_account(event.account_id)
        if account is None:
            account = Account(event)
            if self.account_id.equals(account.id):
                self.account = account
                self.database.add_account(self.account)
                self.portfolio.set_base_currency(event.currency)
                return
        elif account.id == event.account_id:
            account.apply(event)
            self.database.update_account(account)
            return

        self._log.warning(f"Cannot process event {event}, "
                          f"event {event.account_id.to_string(with_class=True)} "
                          f"does not match traders {self.account_id.to_string(with_class=True)}.")

    cdef PositionOpened _pos_opened_event(self,
            Position position,
            OrderFilled event,
            StrategyId strategy_id,
    ):
        return PositionOpened(
            position,
            event,
            strategy_id,
            self._uuid_factory.generate(),
            event.timestamp,
        )

    cdef PositionModified _pos_modified_event(
            self,
            Position position,
            OrderFilled event,
            StrategyId strategy_id,
    ):
        return PositionModified(
            position,
            event,
            strategy_id,
            self._uuid_factory.generate(),
            event.timestamp,
        )

    cdef PositionClosed _pos_closed_event(
            self,
            Position position,
            OrderFilled event,
            StrategyId strategy_id,
    ):
        return PositionClosed(
            position,
            event,
            strategy_id,
            self._uuid_factory.generate(),
            event.timestamp,
        )

    cdef void _send_to_strategy(self, Event event, StrategyId strategy_id) except *:
        if strategy_id is None:
            self._log.error(f"Cannot send event {event} to strategy, "
                            f"{strategy_id.to_string(with_class=True)} not found.")
            return  # Cannot send to strategy

        cdef TradingStrategy strategy = self._registered_strategies.get(strategy_id)
        if strategy_id is None:
            self._log.error(f"Cannot send event {event} to strategy, "
                            f"{strategy_id.to_string(with_class=True)} not registered.")
            return

        strategy.handle_event(event)

    cdef void _reset(self) except *:
        """
        Reset the execution engine to its initial state.
        """
        self._registered_strategies.clear()
        self._pos_id_generator.reset()
        self.command_count = 0
        self.event_count = 0


cdef class LiveExecutionEngine(ExecutionEngine):
    """
    Provides a process and thread safe high performance execution engine.
    """

    def __init__(
            self,
            TraderId trader_id not None,
            AccountId account_id not None,
            ExecutionDatabase database not None,
            OMSType oms_type,
            Portfolio portfolio not None,
            Clock clock not None,
            UUIDFactory uuid_factory not None,
            Logger logger not None,
    ):
        """
        Initialize a new instance of the LiveExecutionEngine class.

        Parameters
        ----------
        trader_id : TraderId
            The trader identifier for the engine.
        account_id : AccountId
            The account_id for the engine.
        database : ExecutionDatabase
            The execution database for the engine.
        oms_type : OMSType
            The order management type for the engine.
        portfolio : Portfolio
            The portfolio for the engine.
        clock : Clock
            The clock for the engine.
        uuid_factory : UUIDFactory
            The uuid factory for the engine.
        logger : Logger
            The logger for the engine.

        """
        super().__init__(
            trader_id=trader_id,
            account_id=account_id,
            database=database,
            oms_type=oms_type,
            portfolio=portfolio,
            clock=clock,
            uuid_factory=uuid_factory,
            logger=logger,
        )

        self._queue = queue.Queue()
        self._thread = threading.Thread(target=self._loop, daemon=True)
        self._thread.start()

    cpdef void execute(self, Command command) except *:
        """
        Execute the given command by inserting it into the message bus for processing.

        Parameters
        ----------
        command : Command
            The command to execute.

        """
        Condition.not_none(command, "command")

        self._queue.put(command)

    cpdef void process(self, Event event) except *:
        """
        Handle the given event by inserting it into the message bus for processing.

        Parameters
        ----------
        event : Event
            The event to process.

        """
        Condition.not_none(event, "event")

        self._queue.put(event)

    cpdef void _loop(self) except *:
        self._log.info("Running...")

        cdef Message message
        while True:
            message = self._queue.get()

            if message.message_type == MessageType.EVENT:
                self._handle_event(message)
            elif message.message_type == MessageType.COMMAND:
                self._execute_command(message)
            else:
                self._log.error(f"Invalid message type on queue ({repr(message)}).")
