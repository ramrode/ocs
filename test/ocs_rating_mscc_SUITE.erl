%%% ocs_rating_mscc_SUITE.erl
%%% vim: ts=3
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%%% @copyright 2026 SigScale Global Inc.
%%% @end
%%% Licensed under the Apache License, Version 2.0 (the "License");
%%% you may not use this file except in compliance with the License.
%%% You may obtain a copy of the License at
%%%
%%%     http://www.apache.org/licenses/LICENSE-2.0
%%%
%%% Unless required by applicable law or agreed to in writing, software
%%% distributed under the License is distributed on an "AS IS" BASIS,
%%% WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
%%% See the License for the specific language governing permissions and
%%% limitations under the License.
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%%%  @doc Test suite for new multiple services credit control (MSCC)
%%% 	rating API in the {@link //ocs. ocs} application.
%%%
-module(ocs_rating_mscc_SUITE).
-copyright('Copyright (c) 2026 SigScale Global Inc.').

%% common_test required callbacks
-export([suite/0, sequences/0, all/0]).
-export([init_per_suite/1, end_per_suite/1]).
-export([init_per_testcase/2, end_per_testcase/2]).

% export test cases
-export([initial_cud_data/0, initial_cud_data/1,
		initial_cud_voice/0, initial_cud_voice/1,
		initial_cud_cents/0, initial_cud_cents/1,
		interim_cud_data/0, interim_cud_data/1,
		interim_cud_voice/0, interim_cud_voice/1,
		interim_cud_cents/0, interim_cud_cents/1,
		final_cud_data/0, final_cud_data/1,
		final_cud_voice/0, final_cud_voice/1,
		final_cud_cents/0, final_cud_cents/1]).

%% export test cases
-behaviour(ct_suite).

-include("ocs.hrl").
-include("ocs_log.hrl").
-include_lib("radius/include/radius.hrl").
-include_lib("common_test/include/ct.hrl").

%%---------------------------------------------------------------------
%%  Test server callback functions
%%---------------------------------------------------------------------

-spec suite() -> DefaultData :: [tuple()].
%% Require variables and set default values for the suite.
%%
suite() ->
	Description = "Test suite for MSCC rating API in OCS",
	ct:comment(Description),
	[{userdata, [{doc, Description}]},
	{timetrap, {minutes, 1}}].

-spec init_per_suite(Config :: [tuple()]) -> Config :: [tuple()].
%% Initialization before the whole suite.
%%
init_per_suite(Config) ->
	ok = ocs_test_lib:initialize_db(),
	ok = ocs_test_lib:start(),
	Config.

-spec end_per_suite(Config :: [tuple()]) -> any().
%% Cleanup after the whole suite.
%%
end_per_suite(Config) ->
	ok = ocs_test_lib:stop(),
	Config.

-spec init_per_testcase(TestCase :: atom(), Config :: [tuple()]) -> Config :: [tuple()].
%% Initialization before each test case.
%%
init_per_testcase(_TestCase, Config) ->
	Config.

-spec end_per_testcase(TestCase :: atom(), Config :: [tuple()]) -> any().
%% Cleanup after each test case.
%%
end_per_testcase(_TestCase, _Config) ->
	ok.

-spec sequences() -> Sequences :: [{SeqName :: atom(), Testcases :: [atom()]}].
%% Group test cases into a test sequence.
%%
sequences() ->
	[].

-spec all() -> TestCases :: [Case :: atom()].
%% Returns a list of all test cases in this test suite.
%%
all() ->
	[initial_cud_data, initial_cud_voice, initial_cud_cents,
			interim_cud_data, interim_cud_voice, interim_cud_cents,
			final_cud_data, final_cud_voice, final_cud_cents].

%%---------------------------------------------------------------------
%%  Test cases
%%---------------------------------------------------------------------

initial_cud_data() ->
	Description = "Initial MSCC data with Centralized Unit Determination (CUD)",
	ct:comment(Description),
	[{userdata, [{doc, Description}]}].

initial_cud_data(_Config) ->
	{ok, MinReserve} = application:get_env(ocs, min_reserve_octets),
	PackageSize1 = MinReserve + rand:uniform(MinReserve - 1),
	PackageSize2 = MinReserve + rand:uniform(MinReserve - 1),
	PackageSize3 = MinReserve + rand:uniform(MinReserve - 1),
	PackagePrice1 = 0,
	PackagePrice2 = rand:uniform(10000000),
	PackagePrice3 = rand:uniform(10000000),
	PackageUnits = octets,
	RG1 = rand:uniform(100) - 1,
	RG2 = rand:uniform(100) - 1,
	RG3 = rand:uniform(100) - 1,
	PriceType = usage,
	P1 = price(PriceType, PackageUnits, PackageSize1, PackagePrice1, RG1),
	P2 = price(PriceType, PackageUnits, PackageSize2, PackagePrice2, RG2),
	P3 = price(PriceType, PackageUnits, PackageSize3, PackagePrice3, RG3),
	OfferId = add_offer([P1, P2, P3], 8),
	ProdRef = add_product(OfferId),
	ServiceId = add_service(ProdRef),
	RemainAmount1 = (PackageSize1 + PackageSize2 + PackageSize3) * 10,
	Bucket = bucket(PackageUnits, RemainAmount1),
	BucketId = add_bucket(ProdRef, Bucket),
	Timestamp = calendar:local_time(),
	Protocol = protocol(),
	ServiceType = service_type(Protocol, data),
	SessionId = session_id(Protocol),
	MSCC1 = #{rating_group => RG1, reserve => []}, 
	MSCC2 = #{rating_group => RG2, reserve => []}, 
	MSCC3 = #{rating_group => RG3, reserve => []}, 
	ServiceUsage = [MSCC1, MSCC2, MSCC3],
	{ok, ServiceRating} = ocs_rating:rate(Protocol, ServiceType,
			undefined, [ServiceId], Timestamp, undefined, undefined,
			initial, SessionId, ServiceUsage),
	[RG1, RG2, RG3] = [RG || #{rating_group := RG} <- ServiceRating],
	Fall = fun(#{rating_group := RG, result := success, grant := Grant})
					when RG == RG1, Grant == [{PackageUnits, PackageSize1}] ->
				true;
			(#{rating_group := RG, result := success, grant := Grant})
					when RG == RG2, Grant == [{PackageUnits, PackageSize2}] ->
				true;
			(#{rating_group := RG, result := success, grant := Grant})
					when RG == RG3, Grant == [{PackageUnits, PackageSize3}] ->
				true;
			(#{}) ->
				false
	end,
	true = lists:all(Fall, ServiceRating),
	Reserve = PackagePrice1 + PackageSize2 + PackageSize3,
	RemainAmount2 = RemainAmount1 - Reserve,
	{ok, #bucket{remain_amount = RemainAmount2,
			attributes = #{reservations := R}}} = ocs:find_bucket(BucketId),
	#{SessionId := #{reserve := Reserve}} = R.

initial_cud_voice() ->
	Description = "Initial MSCC voice with CUD, seconds balance",
	ct:comment(Description),
	[{userdata, [{doc, Description}]}].

initial_cud_voice(_Config) ->
	{ok, MinReserve} = application:get_env(ocs, min_reserve_seconds),
	PackageSize1 = MinReserve + rand:uniform(MinReserve - 1),
	PackageSize2 = MinReserve + rand:uniform(MinReserve - 1),
	PackageSize3 = MinReserve + rand:uniform(MinReserve - 1),
	PackagePrice1 = 0,
	PackagePrice2 = rand:uniform(10000000),
	PackagePrice3 = rand:uniform(10000000),
	PackageUnits = seconds,
	RG1 = rand:uniform(100) - 1,
	RG2 = rand:uniform(100) - 1,
	RG3 = rand:uniform(100) - 1,
	PriceType = usage,
	P1 = price(PriceType, PackageUnits, PackageSize1, PackagePrice1, RG1),
	P2 = price(PriceType, PackageUnits, PackageSize2, PackagePrice2, RG2),
	P3 = price(PriceType, PackageUnits, PackageSize3, PackagePrice3, RG3),
	OfferId = add_offer([P1, P2, P3], 9),
	ProdRef = add_product(OfferId),
	ServiceId = add_service(ProdRef),
	RemainAmount1 = (PackageSize1 + PackageSize2 + PackageSize3) * 10,
	Bucket = bucket(PackageUnits, RemainAmount1),
	BucketId = add_bucket(ProdRef, Bucket),
	Timestamp = calendar:local_time(),
	Protocol = protocol(),
	ServiceType = service_type(Protocol, voice),
	Address = ocs_test_lib:rand_dn(),
	Direction = originate,
	SessionId = session_id(Protocol),
	MSCC1 = #{rating_group => RG1, reserve => []}, 
	MSCC2 = #{rating_group => RG2, reserve => []}, 
	MSCC3 = #{rating_group => RG3, reserve => []}, 
	ServiceUsage = [MSCC1, MSCC2, MSCC3],
	{ok, ServiceRating} = ocs_rating:rate(Protocol, ServiceType,
			undefined, [ServiceId], Timestamp, Address, Direction,
			initial, SessionId, ServiceUsage),
	[RG1, RG2, RG3] = [RG || #{rating_group := RG} <- ServiceRating],
	Fall = fun(#{rating_group := RG, result := success, grant := Grant})
					when RG == RG1, Grant == [{PackageUnits, PackageSize1}] ->
				true;
			(#{rating_group := RG, result := success, grant := Grant})
					when RG == RG2, Grant == [{PackageUnits, PackageSize2}] ->
				true;
			(#{rating_group := RG, result := success, grant := Grant})
					when RG == RG3, Grant == [{PackageUnits, PackageSize3}] ->
				true;
			(#{}) ->
				false
	end,
	true = lists:all(Fall, ServiceRating),
	Reserved = PackagePrice1 + PackageSize2 + PackageSize3,
	RemainAmount2 = RemainAmount1 - Reserved,
	{ok, #bucket{remain_amount = RemainAmount2,
			attributes = #{reservations := R}}} = ocs:find_bucket(BucketId),
	#{SessionId := #{reserve := Reserve}} = R.

initial_cud_cents() ->
	Description = "Initial MSCC data with CUD, conversion from monetary balance",
	ct:comment(Description),
	[{userdata, [{doc, Description}]}].

initial_cud_cents(_Config) ->
	{ok, MinReserve} = application:get_env(ocs, min_reserve_octets),
	PackageSize1 = MinReserve + rand:uniform(MinReserve - 1),
	PackageSize2 = MinReserve + rand:uniform(MinReserve - 1),
	PackageSize3 = MinReserve + rand:uniform(MinReserve - 1),
	PackagePrice1 = 0,
	PackagePrice2 = rand:uniform(10000000),
	PackagePrice3 = rand:uniform(10000000),
	PackageUnits = octets,
	RG1 = rand:uniform(100) - 1,
	RG2 = rand:uniform(100) - 1,
	RG3 = rand:uniform(100) - 1,
	PriceType = usage,
	P1 = price(PriceType, PackageUnits, PackageSize1, PackagePrice1, RG1),
	P2 = price(PriceType, PackageUnits, PackageSize2, PackagePrice2, RG2),
	P3 = price(PriceType, PackageUnits, PackageSize3, PackagePrice3, RG3),
	OfferId = add_offer([P1, P2, P3], 8),
	ProdRef = add_product(OfferId),
	ServiceId = add_service(ProdRef),
	RemainAmount1 = (PackagePrice1 + PackagePrice2 + PackagePrice3) * 10,
	Bucket = bucket(cents, RemainAmount1),
	BucketId = add_bucket(ProdRef, Bucket),
	Timestamp = calendar:local_time(),
	Protocol = protocol(),
	ServiceType = service_type(Protocol, data),
	SessionId = session_id(Protocol),
	MSCC1 = #{rating_group => RG1, reserve => []}, 
	MSCC2 = #{rating_group => RG2, reserve => []}, 
	MSCC3 = #{rating_group => RG3, reserve => []}, 
	ServiceUsage = [MSCC1, MSCC2, MSCC3],
	{ok, ServiceRating} = ocs_rating:rate(Protocol, ServiceType,
			undefined, [ServiceId], Timestamp, undefined, undefined,
			initial, SessionId, ServiceUsage),
	[RG1, RG2, RG3] = [RG || #{rating_group := RG} <- ServiceRating],
	Fall = fun(#{rating_group := RG, result := success, grant := Grant})
					when RG == RG1, Grant == [{PackageUnits, PackageSize1}] ->
				true;
			(#{rating_group := RG, result := success, grant := Grant})
					when RG == RG2, Grant == [{PackageUnits, PackageSize2}] ->
				true;
			(#{rating_group := RG, result := success, grant := Grant})
					when RG == RG3, Grant == [{PackageUnits, PackageSize3}] ->
				true;
			(#{}) ->
				false
	end,
	true = lists:all(Fall, ServiceRating),
	Reserved = (PackagePrice1 + PackagePrice2 + PackagePrice3) * 2,
	RemainAmount2 = RemainAmount1 - Reserved,
	{ok, #bucket{remain_amount = RemainAmount2,
			attributes = #{reservations := R}}} = ocs:find_bucket(BucketId),
	#{SessionId := #{reserve := Reserve}} = R.

interim_cud_data() ->
	Description = "Interim MSCC data with CUD, octets balance",
	ct:comment(Description),
	[{userdata, [{doc, Description}]}].

interim_cud_data(_Config) ->
	{ok, MinReserve} = application:get_env(ocs, min_reserve_octets),
	PackageSize1 = MinReserve + rand:uniform(MinReserve - 1),
	PackageSize2 = MinReserve + rand:uniform(MinReserve - 1),
	PackageSize3 = MinReserve + rand:uniform(MinReserve - 1),
	PackagePrice1 = 0,
	PackagePrice2 = rand:uniform(10000000),
	PackagePrice3 = rand:uniform(10000000),
	PackageUnits = octets,
	RG1 = rand:uniform(100) - 1,
	RG2 = rand:uniform(100) - 1,
	RG3 = rand:uniform(100) - 1,
	PriceType = usage,
	P1 = price(PriceType, PackageUnits, PackageSize1, PackagePrice1, RG1),
	P2 = price(PriceType, PackageUnits, PackageSize2, PackagePrice2, RG2),
	P3 = price(PriceType, PackageUnits, PackageSize3, PackagePrice3, RG3),
	OfferId = add_offer([P1, P2, P3], 8),
	ProdRef = add_product(OfferId),
	ServiceId = add_service(ProdRef),
	RemainAmount1 = (PackageSize1 + PackageSize2 + PackageSize3) * 10,
	Bucket = bucket(PackageUnits, RemainAmount1),
	BucketId = add_bucket(ProdRef, Bucket),
	Timestamp1 = calendar:local_time(),
	TS = calendar:datetime_to_gregorian_seconds(Timestamp1),
	Protocol = protocol(),
	ServiceType = service_type(Protocol, data),
	SessionId = session_id(Protocol),
	MSCC1 = #{rating_group => RG1, reserve => []}, 
	MSCC2 = #{rating_group => RG2, reserve => []}, 
	MSCC3 = #{rating_group => RG3, reserve => []}, 
	ServiceUsage1 = [MSCC1, MSCC2, MSCC3],
	{ok, _ServiceRating1} = ocs_rating:rate(Protocol, ServiceType,
			undefined, [ServiceId], Timestamp1, undefined, undefined,
			initial, SessionId, ServiceUsage1),
	Timestamp2 = calendar:gregorian_seconds_to_datetime(TS + 60),
	Used1 = rand:uniform(PackageSize1),
	Used2 = rand:uniform(PackageSize2),
	Used3 = rand:uniform(PackageSize3),
	Debit1 = {PackageUnits, Used1},
	Debit2 = {PackageUnits, Used2},
	Debit3 = {PackageUnits, Used3},
	MSCC4 = #{rating_group => RG1, debit => [Debit1], reserve => []}, 
	MSCC5 = #{rating_group => RG2, debit => [Debit2], reserve => []}, 
	MSCC6 = #{rating_group => RG3, debit => [Debit3], reserve => []}, 
	ServiceUsage2 = [MSCC4, MSCC5, MSCC6],
	{ok, ServiceRating2} = ocs_rating:rate(Protocol, ServiceType,
			undefined, [ServiceId], Timestamp2, undefined, undefined,
			interim, SessionId, ServiceUsage2),
	[RG1, RG2, RG3] = [RG || #{rating_group := RG} <- ServiceRating2],
	Fall = fun(#{rating_group := RG, result := success, grant := Grant})
					when RG == RG1, Grant == [{PackageUnits, PackageSize1}] ->
				true;
			(#{rating_group := RG, result := success, grant := Grant})
					when RG == RG2, Grant == [{PackageUnits, PackageSize2}] ->
				true;
			(#{rating_group := RG, result := success, grant := Grant})
					when RG == RG3, Grant == [{PackageUnits, PackageSize3}] ->
				true;
			(#{}) ->
				false
	end,
	true = lists:all(Fall, ServiceRating2),
	Reserved = (PackageSize1 + PackageSize2 + PackageSize3) * 2,
	RemainAmount2 = RemainAmount1 - Reserved,
	{ok, #bucket{remain_amount = RemainAmount2,
			attributes = #{reservations := R}}} = ocs:find_bucket(BucketId),
	#{SessionId := #{reserve := Reserve}} = R.

interim_cud_voice() ->
	Description = "Interim MSCC voice with CUD, seconds balance",
	ct:comment(Description),
	[{userdata, [{doc, Description}]}].

interim_cud_voice(_Config) ->
	{ok, MinReserve} = application:get_env(ocs, min_reserve_seconds),
	PackageSize1 = MinReserve + rand:uniform(MinReserve - 1),
	PackageSize2 = MinReserve + rand:uniform(MinReserve - 1),
	PackageSize3 = MinReserve + rand:uniform(MinReserve - 1),
	PackagePrice1 = 0,
	PackagePrice2 = rand:uniform(10000000),
	PackagePrice3 = rand:uniform(10000000),
	PackageUnits = seconds,
	RG1 = rand:uniform(100) - 1,
	RG2 = rand:uniform(100) - 1,
	RG3 = rand:uniform(100) - 1,
	PriceType = usage,
	P1 = price(PriceType, PackageUnits, PackageSize1, PackagePrice1, RG1),
	P2 = price(PriceType, PackageUnits, PackageSize2, PackagePrice2, RG2),
	P3 = price(PriceType, PackageUnits, PackageSize3, PackagePrice3, RG3),
	OfferId = add_offer([P1, P2, P3], 9),
	ProdRef = add_product(OfferId),
	ServiceId = add_service(ProdRef),
	RemainAmount1 = (PackageSize1 + PackageSize2 + PackageSize3) * 10,
	Bucket = bucket(PackageUnits, RemainAmount1),
	BucketId = add_bucket(ProdRef, Bucket),
	Timestamp1 = calendar:local_time(),
	TS = calendar:datetime_to_gregorian_seconds(Timestamp1),
	Protocol = protocol(),
	ServiceType = service_type(Protocol, voice),
	Address = ocs_test_lib:rand_dn(),
	Direction = originate,
	SessionId = session_id(Protocol),
	MSCC1 = #{rating_group => RG1, reserve => []}, 
	MSCC2 = #{rating_group => RG2, reserve => []}, 
	MSCC3 = #{rating_group => RG3, reserve => []}, 
	ServiceUsage = [MSCC1, MSCC2, MSCC3],
	{ok, _ServiceRating1} = ocs_rating:rate(Protocol, ServiceType,
			undefined, [ServiceId], Timestamp1, Address, Direction,
			initial, SessionId, ServiceUsage),
	Timestamp2 = calendar:gregorian_seconds_to_datetime(TS + 60),
	Used1 = rand:uniform(PackageSize1),
	Used2 = rand:uniform(PackageSize2),
	Used3 = rand:uniform(PackageSize3),
	Debit1 = {PackageUnits, Used1},
	Debit2 = {PackageUnits, Used2},
	Debit3 = {PackageUnits, Used3},
	MSCC4 = #{rating_group => RG1, debit => [Debit1], reserve => []}, 
	MSCC5 = #{rating_group => RG2, debit => [Debit2], reserve => []}, 
	MSCC6 = #{rating_group => RG3, debit => [Debit3], reserve => []}, 
	ServiceUsage2 = [MSCC4, MSCC5, MSCC6],
	{ok, ServiceRating2} = ocs_rating:rate(Protocol, ServiceType,
			undefined, [ServiceId], Timestamp2, Address, Direction,
			interim, SessionId, ServiceUsage2),
	[RG1, RG2, RG3] = [RG || #{rating_group := RG} <- ServiceRating2],
	Fall = fun(#{rating_group := RG, result := success, grant := Grant})
					when RG == RG1, Grant == [{PackageUnits, PackageSize1}] ->
				true;
			(#{rating_group := RG, result := success, grant := Grant})
					when RG == RG2, Grant == [{PackageUnits, PackageSize2}] ->
				true;
			(#{rating_group := RG, result := success, grant := Grant})
					when RG == RG3, Grant == [{PackageUnits, PackageSize3}] ->
				true;
			(#{}) ->
				false
	end,
	true = lists:all(Fall, ServiceRating2),
	Reserved = (PackageSize1 + PackageSize2 + PackageSize3) * 2,
	RemainAmount2 = RemainAmount1 - Reserved,
	{ok, #bucket{remain_amount = RemainAmount2,
			attributes = #{reservations := R}}} = ocs:find_bucket(BucketId),
	#{SessionId := #{reserve := Reserve}} = R.

interim_cud_cents() ->
	Description = "Interim MSCC data with CUD, conversion from monetary balance",
	ct:comment(Description),
	[{userdata, [{doc, Description}]}].

interim_cud_cents(_Config) ->
	{ok, MinReserve} = application:get_env(ocs, min_reserve_octets),
	PackageSize1 = MinReserve + rand:uniform(MinReserve - 1),
	PackageSize2 = MinReserve + rand:uniform(MinReserve - 1),
	PackageSize3 = MinReserve + rand:uniform(MinReserve - 1),
	PackagePrice1 = 0,
	PackagePrice2 = rand:uniform(10000000),
	PackagePrice3 = rand:uniform(10000000),
	PackageUnits = octets,
	RG1 = rand:uniform(100) - 1,
	RG2 = rand:uniform(100) - 1,
	RG3 = rand:uniform(100) - 1,
	PriceType = usage,
	P1 = price(PriceType, PackageUnits, PackageSize1, PackagePrice1, RG1),
	P2 = price(PriceType, PackageUnits, PackageSize2, PackagePrice2, RG2),
	P3 = price(PriceType, PackageUnits, PackageSize3, PackagePrice3, RG3),
	OfferId = add_offer([P1, P2, P3], 8),
	ProdRef = add_product(OfferId),
	ServiceId = add_service(ProdRef),
	RemainAmount1 = (PackagePrice1 + PackagePrice2 + PackagePrice3) * 10,
	Bucket = bucket(cents, RemainAmount1),
	BucketId = add_bucket(ProdRef, Bucket),
	Timestamp1 = calendar:local_time(),
	TS = calendar:datetime_to_gregorian_seconds(Timestamp1),
	Protocol = protocol(),
	ServiceType = service_type(Protocol, data),
	SessionId = session_id(Protocol),
	MSCC1 = #{rating_group => RG1, reserve => []}, 
	MSCC2 = #{rating_group => RG2, reserve => []}, 
	MSCC3 = #{rating_group => RG3, reserve => []}, 
	ServiceUsage = [MSCC1, MSCC2, MSCC3],
	{ok, _ServiceRating1} = ocs_rating:rate(Protocol, ServiceType,
			undefined, [ServiceId], Timestamp1, undefined, undefined,
			initial, SessionId, ServiceUsage),
	Timestamp2 = calendar:gregorian_seconds_to_datetime(TS + 60),
	Used1 = rand:uniform(PackageSize1),
	Used2 = rand:uniform(PackageSize2),
	Used3 = rand:uniform(PackageSize3),
	Debit1 = {PackageUnits, Used1},
	Debit2 = {PackageUnits, Used2},
	Debit3 = {PackageUnits, Used3},
	MSCC4 = #{rating_group => RG1, debit => [Debit1], reserve => []}, 
	MSCC5 = #{rating_group => RG2, debit => [Debit2], reserve => []}, 
	MSCC6 = #{rating_group => RG3, debit => [Debit3], reserve => []}, 
	ServiceUsage2 = [MSCC4, MSCC5, MSCC6],
	{ok, ServiceRating2} = ocs_rating:rate(Protocol, ServiceType,
			undefined, [ServiceId], Timestamp2, undefined, undefined,
			interim, SessionId, ServiceUsage2),
	[RG1, RG2, RG3] = [RG || #{rating_group := RG} <- ServiceRating2],
	Fall = fun(#{rating_group := RG, result := success, grant := Grant})
					when RG == RG1, Grant == [{PackageUnits, PackageSize1}] ->
				true;
			(#{rating_group := RG, result := success, grant := Grant})
					when RG == RG2, Grant == [{PackageUnits, PackageSize2}] ->
				true;
			(#{rating_group := RG, result := success, grant := Grant})
					when RG == RG3, Grant == [{PackageUnits, PackageSize3}] ->
				true;
			(#{}) ->
				false
	end,
	true = lists:all(Fall, ServiceRating2),
	Reserved = (PackagePrice1 + PackagePrice2 + PackagePrice3) * 2,
	RemainAmount2 = RemainAmount1 - Reserved,
	{ok, #bucket{remain_amount = RemainAmount2,
			attributes = #{reservations := R}}} = ocs:find_bucket(BucketId),
	#{SessionId := #{reserve := Reserve}} = R.

final_cud_data() ->
	Description = "Final MSCC data with CUD, octets balance",
	ct:comment(Description),
	[{userdata, [{doc, Description}]}].

final_cud_data(_Config) ->
	{ok, MinReserve} = application:get_env(ocs, min_reserve_octets),
	PackageSize1 = MinReserve + rand:uniform(MinReserve - 1),
	PackageSize2 = MinReserve + rand:uniform(MinReserve - 1),
	PackageSize3 = MinReserve + rand:uniform(MinReserve - 1),
	PackagePrice1 = 0,
	PackagePrice2 = rand:uniform(10000000),
	PackagePrice3 = rand:uniform(10000000),
	PackageUnits = octets,
	RG1 = rand:uniform(100) - 1,
	RG2 = rand:uniform(100) - 1,
	RG3 = rand:uniform(100) - 1,
	PriceType = usage,
	#price{name = POP1} = P1 = price(PriceType,
			PackageUnits, PackageSize1, PackagePrice1, RG1),
	#price{name = POP2} = P2 = price(PriceType,
			PackageUnits, PackageSize2, PackagePrice2, RG2),
	#price{name = POP3} = P3 = price(PriceType,
			PackageUnits, PackageSize3, PackagePrice3, RG3),
	OfferId = add_offer([P1, P2, P3], 8),
	ProdRef = add_product(OfferId),
	ServiceId = add_service(ProdRef),
	RemainAmount1 = (PackageSize1 + PackageSize2 + PackageSize3) * 10,
	Bucket = bucket(PackageUnits, RemainAmount1),
	BucketId = add_bucket(ProdRef, Bucket),
	Timestamp1 = calendar:local_time(),
	TS = calendar:datetime_to_gregorian_seconds(Timestamp1),
	Protocol = protocol(),
	ServiceType = service_type(Protocol, data),
	SessionId = session_id(Protocol),
	MSCC1 = #{rating_group => RG1, reserve => []}, 
	MSCC2 = #{rating_group => RG2, reserve => []}, 
	MSCC3 = #{rating_group => RG3, reserve => []}, 
	ServiceUsage1 = [MSCC1, MSCC2, MSCC3],
	{ok, _ServiceRating1} = ocs_rating:rate(Protocol, ServiceType,
			undefined, [ServiceId], Timestamp1, undefined, undefined,
			initial, SessionId, ServiceUsage1),
	Timestamp2 = calendar:gregorian_seconds_to_datetime(TS + 60),
	Used1 = rand:uniform(PackageSize1),
	Used2 = rand:uniform(PackageSize2),
	Used3 = rand:uniform(PackageSize3),
	Debit1 = {PackageUnits, Used1},
	Debit2 = {PackageUnits, Used2},
	Debit3 = {PackageUnits, Used3},
	MSCC4 = #{rating_group => RG1, debit => [Debit1], reserve => []}, 
	MSCC5 = #{rating_group => RG2, debit => [Debit2], reserve => []}, 
	MSCC6 = #{rating_group => RG3, debit => [Debit3], reserve => []}, 
	ServiceUsage2 = [MSCC4, MSCC5, MSCC6],
	{ok, _ServiceRating2} = ocs_rating:rate(Protocol, ServiceType,
			undefined, [ServiceId], Timestamp2, undefined, undefined,
			interim, SessionId, ServiceUsage2),
	Timestamp3 = calendar:gregorian_seconds_to_datetime(TS + 90),
	Used4 = rand:uniform(PackageSize1),
	Used5 = rand:uniform(PackageSize2),
	Used6 = rand:uniform(PackageSize3),
	Debit4 = {PackageUnits, Used1},
	Debit5 = {PackageUnits, Used2},
	Debit6 = {PackageUnits, Used3},
	MSCC7 = #{rating_group => RG1, debit => [Debit4]}, 
	MSCC8 = #{rating_group => RG2, debit => [Debit5]}, 
	MSCC9 = #{rating_group => RG3, debit => [Debit6]}, 
	ServiceUsage3 = [MSCC7, MSCC8, MSCC9],
	{ok, ServiceRating3, Rated} = ocs_rating:rate(Protocol, ServiceType,
			undefined, [ServiceId], Timestamp3, undefined, undefined,
			final, SessionId, ServiceUsage3),
	[RG1, RG2, RG3] = [RG || #{rating_group := RG} <- ServiceRating3],
	Fall = fun(#{rating_group := RG, result := success})
					when RG == RG1 ->
				true;
			(#{rating_group := RG, result := success})
					when RG == RG2 ->
				true;
			(#{rating_group := RG, result := success})
					when RG == RG3 ->
				true;
			(#{}) ->
				false
	end,
	true = lists:all(Fall, ServiceRating3),
	Billed1 = case ((Used1 + Used4) rem PackageSize1) of
		0 ->
			(Used1 + Used4) div PackageSize1;
		_ ->
			((Used1 + Used4) div PackageSize1) + 1
	end,
	Billed2 = case ((Used2 + Used5) rem PackageSize2) of
		0 ->
			(Used2 + Used5) div PackageSize2;
		_ ->
			((Used2 + Used5) div PackageSize2) + 1
	end,
	Billed3 = case ((Used3 + Used6) rem PackageSize3) of
		0 ->
			(Used3 + Used6) div PackageSize3;
		_ ->
			((Used3 + Used6) div PackageSize3) + 1
	end,
	[Rated1, Rated2, Rated3] = Rated,
	#rated{product = OfferId, price_name = POP1,
			price_type = usage, usage_rating_tag = included,
			bucket_type = PackageUnits, is_billed = true,
			bucket_value = Billed1} = Rated1,
	#rated{product = OfferId, price_name = POP2,
			price_type = usage, usage_rating_tag = included,
			bucket_type = PackageUnits, is_billed = true,
			bucket_value = Billed2} = Rated2,
	#rated{product = OfferId, price_name = POP3,
			price_type = usage, usage_rating_tag = included,
			bucket_type = PackageUnits, is_billed = true,
			bucket_value = Billed3} = Rated3,
	RemainAmount2 = RemainAmount1 - Billed1 - Billed2 - Billed3,
	{ok, #bucket{remain_amount = RemainAmount2,
			attributes = BucketAttributes}} = ocs:find_bucket(BucketId),
	false = is_map_key(reservations, BucketAttributes).

final_cud_voice() ->
	Description = "Final MSCC voice with CUD, seconds balance",
	ct:comment(Description),
	[{userdata, [{doc, Description}]}].

final_cud_voice(_Config) ->
	{ok, MinReserve} = application:get_env(ocs, min_reserve_seconds),
	PackageSize1 = MinReserve + rand:uniform(MinReserve - 1),
	PackageSize2 = MinReserve + rand:uniform(MinReserve - 1),
	PackageSize3 = MinReserve + rand:uniform(MinReserve - 1),
	PackagePrice1 = 0,
	PackagePrice2 = rand:uniform(10000000),
	PackagePrice3 = rand:uniform(10000000),
	PackageUnits = seconds,
	RG1 = rand:uniform(100) - 1,
	RG2 = rand:uniform(100) - 1,
	RG3 = rand:uniform(100) - 1,
	PriceType = usage,
	#price{name = POP1} = P1 = price(PriceType,
			PackageUnits, PackageSize1, PackagePrice1, RG1),
	#price{name = POP2} = P2 = price(PriceType,
			PackageUnits, PackageSize2, PackagePrice2, RG2),
	#price{name = POP3} = P3 = price(PriceType,
			PackageUnits, PackageSize3, PackagePrice3, RG3),
	OfferId = add_offer([P1, P2, P3], 9),
	ProdRef = add_product(OfferId),
	ServiceId = add_service(ProdRef),
	RemainAmount1 = (PackageSize1 + PackageSize2 + PackageSize3) * 10,
	Bucket = bucket(PackageUnits, RemainAmount1),
	BucketId = add_bucket(ProdRef, Bucket),
	Timestamp1 = calendar:local_time(),
	TS = calendar:datetime_to_gregorian_seconds(Timestamp1),
	Protocol = protocol(),
	ServiceType = service_type(Protocol, voice),
	Address = ocs_test_lib:rand_dn(),
	Direction = originate,
	SessionId = session_id(Protocol),
	MSCC1 = #{rating_group => RG1, reserve => []}, 
	MSCC2 = #{rating_group => RG2, reserve => []}, 
	MSCC3 = #{rating_group => RG3, reserve => []}, 
	ServiceUsage = [MSCC1, MSCC2, MSCC3],
	{ok, _ServiceRating1} = ocs_rating:rate(Protocol, ServiceType,
			undefined, [ServiceId], Timestamp1, Address, Direction,
			initial, SessionId, ServiceUsage),
	Timestamp2 = calendar:gregorian_seconds_to_datetime(TS + 60),
	Used1 = rand:uniform(PackageSize1),
	Used2 = rand:uniform(PackageSize2),
	Used3 = rand:uniform(PackageSize3),
	Debit1 = {PackageUnits, Used1},
	Debit2 = {PackageUnits, Used2},
	Debit3 = {PackageUnits, Used3},
	MSCC4 = #{rating_group => RG1, debit => [Debit1], reserve => []}, 
	MSCC5 = #{rating_group => RG2, debit => [Debit2], reserve => []}, 
	MSCC6 = #{rating_group => RG3, debit => [Debit3], reserve => []}, 
	ServiceUsage2 = [MSCC4, MSCC5, MSCC6],
	{ok, _ServiceRating2} = ocs_rating:rate(Protocol, ServiceType,
			undefined, [ServiceId], Timestamp2, Address, Direction,
			interim, SessionId, ServiceUsage2),
	Timestamp3 = calendar:gregorian_seconds_to_datetime(TS + 90),
	Used4 = rand:uniform(PackageSize1),
	Used5 = rand:uniform(PackageSize2),
	Used6 = rand:uniform(PackageSize3),
	Debit4 = {PackageUnits, Used1},
	Debit5 = {PackageUnits, Used2},
	Debit6 = {PackageUnits, Used3},
	MSCC7 = #{rating_group => RG1, debit => [Debit4]}, 
	MSCC8 = #{rating_group => RG2, debit => [Debit5]}, 
	MSCC9 = #{rating_group => RG3, debit => [Debit6]}, 
	ServiceUsage3 = [MSCC7, MSCC8, MSCC9],
	{ok, ServiceRating3, Rated} = ocs_rating:rate(Protocol, ServiceType,
			undefined, [ServiceId], Timestamp3, undefined, undefined,
			final, SessionId, ServiceUsage3),
	[RG1, RG2, RG3] = [RG || #{rating_group := RG} <- ServiceRating3],
	Fall = fun(#{rating_group := RG, result := success})
					when RG == RG1 ->
				true;
			(#{rating_group := RG, result := success})
					when RG == RG2 ->
				true;
			(#{rating_group := RG, result := success})
					when RG == RG3 ->
				true;
			(#{}) ->
				false
	end,
	true = lists:all(Fall, ServiceRating3),
	[Rated1, Rated2, Rated3] = Rated,
	Billed1 = case ((Used1 + Used4) rem PackageSize1) of
		0 ->
			(Used1 + Used4) div PackageSize1;
		_ ->
			((Used1 + Used4) div PackageSize1) + 1
	end,
	Billed2 = case ((Used2 + Used5) rem PackageSize2) of
		0 ->
			(Used2 + Used5) div PackageSize2;
		_ ->
			((Used2 + Used5) div PackageSize2) + 1
	end,
	Billed3 = case ((Used3 + Used6) rem PackageSize3) of
		0 ->
			(Used3 + Used6) div PackageSize3;
		_ ->
			((Used3 + Used6) div PackageSize3) + 1
	end,
	#rated{product = OfferId, price_name = POP1,
			price_type = usage, usage_rating_tag = included,
			bucket_type = PackageUnits, is_billed = true,
			bucket_value = Billed1} = Rated1,
	#rated{product = OfferId, price_name = POP2,
			price_type = usage, usage_rating_tag = included,
			bucket_type = PackageUnits, is_billed = true,
			bucket_value = Billed2} = Rated2,
	#rated{product = OfferId, price_name = POP3,
			price_type = usage, usage_rating_tag = included,
			bucket_type = PackageUnits, is_billed = true,
			bucket_value = Billed3} = Rated3,
	RemainAmount2 = RemainAmount1 - Billed1 - Billed2 - Billed3,
	{ok, #bucket{remain_amount = RemainAmount2,
			attributes = BucketAttributes}} = ocs:find_bucket(BucketId),
	false = is_map_key(reservations, BucketAttributes).

final_cud_cents() ->
	Description = "Final MSCC data with CUD, conversion from monetary balance",
	ct:comment(Description),
	[{userdata, [{doc, Description}]}].

final_cud_cents(_Config) ->
	{ok, MinReserve} = application:get_env(ocs, min_reserve_octets),
	PackageSize1 = MinReserve + rand:uniform(MinReserve - 1),
	PackageSize2 = MinReserve + rand:uniform(MinReserve - 1),
	PackageSize3 = MinReserve + rand:uniform(MinReserve - 1),
	PackagePrice1 = 0,
	PackagePrice2 = rand:uniform(10000000),
	PackagePrice3 = rand:uniform(10000000),
	PackageUnits = octets,
	RG1 = rand:uniform(100) - 1,
	RG2 = rand:uniform(100) - 1,
	RG3 = rand:uniform(100) - 1,
	PriceType = usage,
	#price{name = POP1} = P1 = price(PriceType,
			PackageUnits, PackageSize1, PackagePrice1, RG1),
	#price{name = POP2} = P2 = price(PriceType,
			PackageUnits, PackageSize2, PackagePrice2, RG2),
	#price{name = POP3} = P3 = price(PriceType,
			PackageUnits, PackageSize3, PackagePrice3, RG3),
	OfferId = add_offer([P1, P2, P3], 8),
	ProdRef = add_product(OfferId),
	ServiceId = add_service(ProdRef),
	RemainAmount1 = (PackagePrice1 + PackagePrice2 + PackagePrice3) * 10,
	Bucket = bucket(cents, RemainAmount1),
	BucketId = add_bucket(ProdRef, Bucket),
	Timestamp1 = calendar:local_time(),
	TS = calendar:datetime_to_gregorian_seconds(Timestamp1),
	Protocol = protocol(),
	ServiceType = service_type(Protocol, data),
	SessionId = session_id(Protocol),
	MSCC1 = #{rating_group => RG1, reserve => []}, 
	MSCC2 = #{rating_group => RG2, reserve => []}, 
	MSCC3 = #{rating_group => RG3, reserve => []}, 
	ServiceUsage = [MSCC1, MSCC2, MSCC3],
	{ok, _ServiceRating1} = ocs_rating:rate(Protocol, ServiceType,
			undefined, [ServiceId], Timestamp1, undefined, undefined,
			initial, SessionId, ServiceUsage),
	Timestamp2 = calendar:gregorian_seconds_to_datetime(TS + 60),
	Used1 = rand:uniform(PackageSize1),
	Used2 = rand:uniform(PackageSize2),
	Used3 = rand:uniform(PackageSize3),
	Debit1 = {PackageUnits, Used1},
	Debit2 = {PackageUnits, Used2},
	Debit3 = {PackageUnits, Used3},
	MSCC4 = #{rating_group => RG1, debit => [Debit1], reserve => []}, 
	MSCC5 = #{rating_group => RG2, debit => [Debit2], reserve => []}, 
	MSCC6 = #{rating_group => RG3, debit => [Debit3], reserve => []}, 
	ServiceUsage2 = [MSCC4, MSCC5, MSCC6],
	{ok, _ServiceRating2} = ocs_rating:rate(Protocol, ServiceType,
			undefined, [ServiceId], Timestamp2, undefined, undefined,
			interim, SessionId, ServiceUsage2),
	Timestamp3 = calendar:gregorian_seconds_to_datetime(TS + 90),
	Used4 = rand:uniform(PackageSize1),
	Used5 = rand:uniform(PackageSize2),
	Used6 = rand:uniform(PackageSize3),
	Debit4 = {PackageUnits, Used1},
	Debit5 = {PackageUnits, Used2},
	Debit6 = {PackageUnits, Used3},
	MSCC7 = #{rating_group => RG1, debit => [Debit4]}, 
	MSCC8 = #{rating_group => RG2, debit => [Debit5]}, 
	MSCC9 = #{rating_group => RG3, debit => [Debit6]}, 
	ServiceUsage3 = [MSCC7, MSCC8, MSCC9],
	{ok, ServiceRating3, Rated} = ocs_rating:rate(Protocol, ServiceType,
			undefined, [ServiceId], Timestamp3, undefined, undefined,
			final, SessionId, ServiceUsage3),
	[RG1, RG2, RG3] = [RG || #{rating_group := RG} <- ServiceRating3],
	Fall = fun(#{rating_group := RG, result := success})
					when RG == RG1 ->
				true;
			(#{rating_group := RG, result := success})
					when RG == RG2 ->
				true;
			(#{rating_group := RG, result := success})
					when RG == RG3 ->
				true;
			(#{}) ->
				false
	end,
	true = lists:all(Fall, ServiceRating3),
	[Rated1, Rated2, Rated3] = Rated,
	Billed1 = case ((Used1 + Used4) rem PackageSize1) of
		0 ->
			((Used1 + Used4) div PackageSize1) * PackagePrice1;
		_ ->
			(((Used1 + Used4) div PackageSize1) + 1) * PackagePrice1
	end,
	Billed2 = case ((Used2 + Used5) rem PackageSize2) of
		0 ->
			((Used2 + Used5) div PackageSize2) * PackagePrice2;
		_ ->
			(((Used2 + Used5) div PackageSize2) + 1) * PackagePrice2
	end,
	Billed3 = case ((Used3 + Used6) rem PackageSize3) of
		0 ->
			((Used3 + Used6) div PackageSize3) * PackagePrice3;
		_ ->
			(((Used3 + Used6) div PackageSize3) + 1) * PackagePrice3
	end,
	#rated{product = OfferId, price_name = POP1,
			price_type = usage, usage_rating_tag = included,
			bucket_type = PackageUnits, is_billed = true,
			bucket_value = Billed1} = Rated1,
	#rated{product = OfferId, price_name = POP2,
			price_type = usage, usage_rating_tag = included,
			bucket_type = PackageUnits, is_billed = true,
			bucket_value = Billed2} = Rated2,
	#rated{product = OfferId, price_name = POP3,
			price_type = usage, usage_rating_tag = included,
			bucket_type = PackageUnits, is_billed = true,
			bucket_value = Billed3} = Rated3,
	RemainAmount2 = RemainAmount1 - Billed1 - Billed2 - Billed3,
	{ok, #bucket{remain_amount = RemainAmount2,
			attributes = #{reservations := R}}} = ocs:find_bucket(BucketId),
	#{SessionId := #{reserve := Reserve}} = R.

%%---------------------------------------------------------------------
%%  Internal functions
%%---------------------------------------------------------------------

price(Type, Units, Size, Amount, RatingGroup) ->
	CharValue = #char_value{value = RatingGroup},
	CharName = "chargingKey",
	CharValueUse = #char_value_use{name = CharName, values = [CharValue]},
	#price{name = ocs:generate_identity(),
			type = Type, units = Units,
			size = Size, amount = Amount,
			char_value_use = [CharValueUse]}.

add_offer(Prices, Spec) when is_integer(Spec) ->
	add_offer(Prices, integer_to_list(Spec));
add_offer(Prices, Spec) ->
	Offer = #offer{name = ocs:generate_identity(),
			price = Prices,
			specification = Spec},
	{ok, #offer{name = OfferId}} = ocs:add_offer(Offer),
	OfferId.

add_product(OfferId) ->
	add_product(OfferId, []).
add_product(OfferId, Chars) ->
	add_product(OfferId, [], Chars).
add_product(OfferId, ServiceRefs, Chars) ->
	{ok, #product{id = ProdRef}} = ocs:add_product(OfferId,
			ServiceRefs, Chars),
	ProdRef.

add_service(ProdRef) ->
	ServiceId = ocs:generate_identity(),
	{ok, _Service1} = ocs:add_service(ServiceId, undefined, ProdRef, []),
	ServiceId.

add_bucket(ProdRef, Bucket) ->
	{ok, _, #bucket{id = BucketId}} = ocs:add_bucket(ProdRef, Bucket),
	BucketId.

protocol() ->
	protocol(rand:uniform(3)).

protocol(1) ->
	radius;
protocol(2) ->
	diameter;
protocol(3) ->
	nrf.

service_type(radius, data) ->
	2;
service_type(radius, voice) ->
	12;
service_type(nrf, data) ->
	32255;
service_type(diameter, data) ->
	32251;
service_type(_, voice) ->
	32260;
service_type(_, message) ->
	32274.

session_id(radius) ->
	SessionId = list_to_binary(ocs:generate_password()),
	AcctSessionId = {?AcctSessionId, SessionId},
	Address = ocs_test_lib:ipv4(),
	NasIp = {?NasIpAddress, Address},
	NasId = {?NasIdentifier, list_to_binary(ocs:generate_password())},
	[NasIp, NasId, AcctSessionId];
session_id(diameter) ->
	SessionId = diameter:session_id(ocs:generate_password()),
	[{'Session-Id', list_to_binary(SessionId)}];
session_id(nrf) ->
	TS = erlang:system_time(millisecond),
	N = erlang:unique_integer([positive]),
	RatingDataRef = integer_to_list(TS) ++ integer_to_list(N),
	[{nrf_ref, list_to_binary(RatingDataRef)}].

bucket(Units, RA) ->
	bucket(Units, RA, []).

bucket(Units, RA, PriceName) ->
	#bucket{units = Units, remain_amount = RA, price = PriceName,
			start_date = erlang:system_time(millisecond),
			end_date = erlang:system_time(millisecond) + 2592000000,
			attributes = #{bucket_type => normal}}.

