%%% mod_oauth.erl
%%% vim: ts=3
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%%% @copyright 2016 - 2026 SigScale Global Inc.
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
%%%
%% @doc This module handles OAuth (Open Authorization) user authentication
%% 	using text files or mnesia database.
%%
%% The module implements the OAuth 2.0 Authorization Framework
%% (<a href="https://tools.ietf.org/html/rfc6749">RFC6749</a>)
%% with requests authenticated by Bearer Tokens
%% (<a href="https://www.rfc-editor.org/info/rfc6750/">RFC6750</a>)
%% as JSON Web Token (JWT)
%% (<a href="https://www.rfc-editor.org/info/rfc7519/">RFC7519</a>).
%% The JWT is validated with the certificate for the issuer using
%% JSON Web Key (JWK)
%% (<a href="https://www.rfc-editor.org/info/rfc7517">RFC7517</a>).
%%
%% The following environment variables must be configured for the
%% {@link //ocs. ocs} application:
%% <dl>
%% 	<dt>`oauth_audience'</dt>
%% 		<dd>The recipient for whom the JWT is intended (`string()'):
%% 		(default: `"sigscale"')</dd>
%%   <dt>`oauth_issuer'</dt>
%% 		<dd>The issuer of the JWT (`string()'):
%% 		(default: `undefined')</dd>
%% 	<dt>`oauth_key'</dt>
%% 		<dd>Path of the PEM format file containing a public key
%% 		(`file:filename()'): (default: `undefined')</dd>
%% </dl>
%%
%% An {@link //inets/httpd. httpd} service, in the {@link //inets. inets}
%% application, is configured by including `mod_oauth' in the list of modules:
%% <pre><code>
%% 	{inets,
%% 		[{services,
%% 			[{httpd,
%% 				[{modules,
%% 					[mod_oauth, ...]}]}]}]}
%% </code></pre>
%% Note: Modules `mod_oauth' and `mod_auth' are mutually exclusive.
%%
-module(mod_oauth).
-copyright('Copyright (c) 2016 - 2026 SigScale Global Inc.').

-export([do/1, load/2, store/2]).

-include_lib("inets/include/httpd.hrl").
-include_lib("inets/include/mod_auth.hrl").
-include_lib("public_key/include/public_key.hrl").

%%----------------------------------------------------------------------
%%  The mod_oauth API
%%----------------------------------------------------------------------

do(#mod{data = Data} = Info) ->
	case lists:keyfind(status, 1, Data) of
		false ->
			case lists:keyfind(response, 1, Data) of
				false ->
					do1(Data, Info);
				_ ->
					{proceed, Data}
			end;
		{_StatusCode, _PhraseArgs, _Reason} ->
			{proceed, Data}
	end.
do1(Data, #mod{config_db = ConfigDb,
		request_uri= RequestUri} = Info) ->
	Path = mod_alias:path(Data, ConfigDb, RequestUri),
	case directory_path(Path, ConfigDb) of
		{ok, {Directory, DirectoryData}} ->
			case proplists:get_value(auth_type, DirectoryData) of
				undefined ->
					{proceed, Data};
				none ->
					{proceed, Data};
				AuthType ->
					handle_auth(Info, Directory, DirectoryData, AuthType)
			end;
		{error, _Reason} ->
			{proceed, Data}
	end.

-dialyzer({no_missing_calls, load/2}).
-spec load(Directory, DirectoryData) -> Result
	when
		Directory :: string(),
		DirectoryData :: [tuple()],
		Result ::  {ok, NewDirectoryData} | {error, Reason},
		Reason :: term(),
		NewDirectoryData :: [tuple()].
%% @doc Look up a directory and set a new context.
load(Directory, DirectoryData)
		when is_list(Directory), is_list(DirectoryData) ->
	mod_auth:load(Directory, DirectoryData).

-spec store(Options, Config) -> Result
	when
		Options :: {Option, Value},
		Config :: [{Option, Value}],
		Option :: atom(),
		Value :: term(),
		Result :: {ok, {Option, NewValue}} | {error, Reason},
		NewValue :: term(),
		Reason :: term().
%% @doc Check the validity of configuration options and save them in the internal database
store({oauth_key, Value}, _ConfigList)
		when is_list(Value) ->
	case file:read_file(Value) of
		{ok, PemBin} ->
			store1(public_key:pem_decode(PemBin));
		{error, Reason} ->
			{error, Reason}
end;
store({oauth_key, #'RSAPublicKey'{} = Value}, _ConfigList) ->
	{ok, {oauth_key, Value}};
store(Options, ConfigList) ->
	mod_auth:store(Options, ConfigList).

%% @hidden
store1([{'Certificate', DerCert, _}]) ->
	case public_key:pkix_decode_cert(DerCert, otp) of
		#'OTPCertificate'{tbsCertificate = TbsCert}  ->
			SubPublicKeyInfo = TbsCert#'OTPTBSCertificate'.subjectPublicKeyInfo,
			NewValue = SubPublicKeyInfo#'OTPSubjectPublicKeyInfo'.subjectPublicKey,
			application:set_env(ocs, oauth_key, NewValue),
			{ok, {oauth_key, NewValue}};
		_ ->
			{error, invalid_pem_entry}
	end;
store1([#'RSAPublicKey'{} = RSAPubEntry]) ->
	case public_key:pem_entry_decode(RSAPubEntry) of
		#'RSAPublicKey'{} = RSAPublicKey ->
			application:set_env(ocs, oauth_key, RSAPublicKey),
			{ok, {oauth_key, RSAPublicKey}};
		_ ->
			{error, invalid_pem_entry}
	end.

%%--------------------------------------------------------------------
%%% Internal functions
%%--------------------------------------------------------------------

-spec handle_auth(Info, Directory, DirectoryData, AuthType) -> Result
	when
		Info :: #mod{},
		Directory :: string(),
		DirectoryData :: [tuple()],
		AuthType :: plain | mnesia | dets,
		Result :: {proceed, #mod{}}.
handle_auth(#mod{parsed_header = RequestHeaders,
				data = Data, config_db = ConfigDb} = Info,
		Directory, DirectoryData, _AuthType) ->
	case require(Info, Directory, DirectoryData) of
		authorized ->
			{proceed, Data};
		{authorized, User} ->
			{proceed, [{remote_user, User} | Data]};
		{authorization_required, Realm} ->
			Message = httpd_util:message(401, none, ConfigDb),
			Problem = #{type => "https://datatracker.ietf.org/doc/html/"
							"rfc7231#section-6.5.4",
					title => "Unauthorized",
					detail => Message,
					code => "", status => 401},
			{ContentType, ResponseBody} = ocs_rest:format_problem(Problem,
					RequestHeaders),
			Size = integer_to_list(iolist_size(ResponseBody)),
			ResponseHeaders = [{content_length, Size},
					{content_type, ContentType},
					{'WWW-Authenticate', ["Bearer realm=", Realm, $"]}],
			send(Info, 401, ResponseHeaders, ResponseBody),
			{proceed, [{response, {already_sent, 401, Size}} | Data]};
		{status, {StatusCode, PhraseArgs, Reason}} ->
			{proceed, [{status, {StatusCode, PhraseArgs, Reason}} | Data]}
	end.

%% @hidden
require(#mod{parsed_header = ParsedHeader} = Info, Directory, DirectoryData) ->
	ValidUsers  = proplists:get_value(require_user, DirectoryData),
	ValidGroups = proplists:get_value(require_group, DirectoryData),
	case ValidGroups of
		undefined when ValidUsers =:= undefined ->
			authorized;
		_ ->
			case proplists:get_value("authorization", ParsedHeader) of
				false ->
					authorization_required(DirectoryData);
				"Bearer " ++ EncodedString = Credentials ->
					case string:tokens(EncodedString, ".") of
						[EncodedHeader, EncodedPayload, EncodedSignature] ->
							require1(Info, Directory, DirectoryData, ValidUsers, ValidGroups,
									EncodedHeader, EncodedPayload, EncodedSignature);
						_ ->
							{status, {401, none, "mod_oauth : " ++ "Bad credentials" ++ Credentials}}
					end;
				BadCredentials ->
					{status, {401, none, "mod_oauth : " ++ "Bad credentials" ++ BadCredentials}}
			end
	end.
%% @hidden
require1(Info, Directory, DirectoryData, ValidUsers, ValidGroups,
		EncodedHeader, EncodedPayload, EncodedSignature)
		when is_list(EncodedHeader), is_list(EncodedPayload), is_list(EncodedSignature) ->
	case validate_header(EncodedHeader) of
		{ok, _DecodedHeader} ->
			case validate_payload(EncodedPayload) of
				{ok, DecodedPayload} ->
					case validate_cert(EncodedHeader, EncodedPayload, EncodedSignature) of
						ok ->
							validate_user(Info, Directory, DirectoryData,
									ValidUsers, ValidGroups, DecodedPayload);
						{error, _Reason} ->
							authorization_required(DirectoryData)
					end;
				{error, _Reason} ->
					authorization_required(DirectoryData)
			end;
		{error, _Reason} ->
			authorization_required(DirectoryData)
	end.

%% @hidden
authorization_required(DirectoryData) ->
	case lists:keyfind(auth_name, 1, DirectoryData) of
		false ->
			{status, {500, none, "mod_auth : " ++ "AuthName directive not specified"}};
		{auth_name, Realm} ->
			{authorization_required, Realm}
	end.

-spec validate_cert(EncodedHeader, EncodedPayLoad, EncodedSignature) -> Result
	when
		EncodedHeader :: string(),
		EncodedPayLoad :: string(),
		EncodedSignature :: string(),
		Result :: ok | {error, Reason},
		Reason :: term().
%% @doc Validate a JWT certificate.
validate_cert(EncodedHeader, EncodedPayLoad, EncodedSignature) ->
		DecodedSignature = decode_base64url(EncodedSignature),
		validate_cert1(EncodedHeader, EncodedPayLoad, iolist_to_binary(DecodedSignature)).
%% @hidden
validate_cert1(EncodedHeader, EncodedPayLoad, DecodedSignature)
		when is_binary(DecodedSignature), DecodedSignature =/= <<>> ->
	try
		{ok, Value} = application:get_env(ocs, oauth_key),
		{ok, {_, RSAPublicKey}} = store({oauth_key, Value}, []),
		Msg = iolist_to_binary([string:strip(EncodedHeader, left), <<".">>, EncodedPayLoad]),
		public_key:verify(Msg, sha256, DecodedSignature, RSAPublicKey)
	of
		true ->
			ok;
		false ->
			{error, invalid}
	catch
		_:Reason ->
			{error, Reason}
	end;
validate_cert1(_EncodedHeader, _EncodedPayLoad, _DecodedSignature) ->
	{error, invalid}.

-spec validate_payload(EncodedPayload) -> Result
	when
		EncodedPayload :: string(),
		Result :: {ok, DecodedPayload} | {error, Reason},
		DecodedPayload :: map(),
		Reason :: term().
%% @doc Validate a JWT payload.
validate_payload(EncodedPayload) ->
		DecodedPayLoad = mochijson:decode(decode_base64url(EncodedPayload)),
		validate_payload1(struct_to_map(DecodedPayLoad)).
%% @hidden
validate_payload1(#{"aud" := Aud, "iss" := Iss, "exp" := Exp} = DecodedPayload)
		when is_list(Aud), is_list(Iss) ->
	{ok, Audience} = application:get_env(ocs, oauth_audience),
	{ok, Issuer} = application:get_env(ocs, oauth_issuer),
	case {Audience, Issuer, erlang:system_time(second)} of
		{Aud, Iss, Now} when Now < Exp ->
			{ok, DecodedPayload};
		{Audience, Iss, Now} when is_list(Audience), Now < Exp ->
			case lists:member(Audience, Aud) of
				true ->
					{ok, DecodedPayload};
				false ->
					{error, invalid}
			end;
		{_, _, _} ->
			{error, invalid}
	end;
validate_payload1(_DecodedPayload) ->
	{error, invalid}.

-spec validate_header(EncodedHeader) -> Result
	when
		EncodedHeader :: string(),
		Result :: {ok, DecodedPayload} | {error, Reason},
		DecodedPayload :: map(),
		Reason :: term().
%% @doc Validate a JWT header.
validate_header(EncodedHeader) ->
	EncodedHeader1 = string:strip(EncodedHeader, left),
	DecodedHeader = mochijson:decode(decode_base64url(EncodedHeader1)),
	validate_header1(struct_to_map(DecodedHeader)).
%% @hidden
validate_header1(#{"alg" := "RS256", "typ" := "JWT"} = DecodedHeader) ->
	{ok, DecodedHeader};
validate_header1(_DecodedHeader) ->
	{error, invalid}.

-spec validate_user(Info, Directory, DirectoryData,
		ValidUsers, ValidGroups, DecodedPayload) -> Result
	when
		Info :: #mod{},
		Directory :: string(),
		DirectoryData :: [tuple()],
		ValidUsers :: list(),
		ValidGroups :: list(),
		DecodedPayload :: map(),
		Result :: {authorized, User} | {authorization_required, Reason} |
				{status, {StatusCode, none, Reason}},
		StatusCode :: integer(),
		User :: string(),
		Reason :: term().
validate_user(Info, Directory, DirectoryData,
		ValidUsers, ValidGroups, #{"email" := Email}) when is_list(Email) ->
	case user_accepted(Email, ValidUsers) of
		true ->
			{authorized, Email};
		false ->
			case user_group_check(Info, Email,
					ValidGroups, Directory,  DirectoryData) of
				true ->
					{authorized, Email};
				false ->
					authorization_required(DirectoryData)
			end
	end;
validate_user(Info, Directory, DirectoryData,
		ValidUsers, ValidGroups, #{"preferred_username" := PrefUserName})
		when is_list(PrefUserName) ->
	case user_accepted(PrefUserName, ValidUsers) of
		true ->
			{authorized, PrefUserName};
		false ->
			case user_group_check(Info, PrefUserName,
					ValidGroups, Directory, DirectoryData) of
				true ->
					{authorized, PrefUserName};
				false ->
					authorization_required(DirectoryData)
			end
	end.

%% @hidden
user_accepted(_User, undefined) ->
	false;
user_accepted(User, ValidUsers) ->
	lists:member(User, ValidUsers).

-spec user_group_check(Info, User, UserGroups,
		Directory, DirectoryData) -> Result
	when
		Info :: #mod{},
		User :: string(),
		UserGroups :: list(),
		Directory :: string(),
		DirectoryData :: [tuple()],
		Result :: boolean().
user_group_check(_Info, _User, undefined,
		_Directory, _DirectoryData) ->
	false;
user_group_check(Info, User, [H | T],
		Directory, DirectoryData) ->
	case get_user_list(Directory, DirectoryData, H) of
		{ok, UserList} ->
			case lists:member(User, UserList) of
				true ->
					true;
				false ->
					user_group_check(Info, User, T,
							Directory, DirectoryData)
				end;
		_ ->
			false
	end;
user_group_check(_Info, _User, [], _Directory, _DirectoryData) ->
	false.

-spec get_user_list(Directory, DirectoryData, Group) -> Result
	when
		Directory :: string(),
		DirectoryData :: [tuple()],
		Group :: string(),
		Result :: {ok, UserList} | {error, Reason},
		UserList :: list(),
		Reason :: term().
get_user_list(Directory, DirectoryData, Group) ->
	case lists:keyfind(auth_type, 1, DirectoryData) of
		{auth_type, plain} ->
			mod_auth_plain:list_group_members(DirectoryData, Group);
		{auth_type, mnesia} ->
			DirectoryData1 = [{path, Directory} | DirectoryData],
			mod_auth_mnesia:list_group_members(DirectoryData1, Group);
		{auth_type, dets} ->
			mod_auth_dets:list_group_members(DirectoryData, Group)
	end.

-spec decode_base64url(EncodedValue) -> DecodedValue
	when
		EncodedValue :: string(),
		DecodedValue :: list().
%% @doc Decode a base64url encoded value.
decode_base64url(EncodedValue)
		when is_list(EncodedValue) ->
	EncodedValue1 = sub_chars(EncodedValue),
	base64:decode_to_string(EncodedValue1).

%% @hidden
sub_chars(List) ->
	case length(List) rem 4 of
		2 ->
			sub_chars1(List ++ "==", []);
		3 ->
			sub_chars1(List ++ "=", []);
		_ ->
			sub_chars1(List, [])
	end.

%% @hidden
sub_chars1([$_ | T], Acc) ->
	sub_chars1(T, [$/ | Acc]);
sub_chars1([$- | T], Acc) ->
	sub_chars1(T, [$+ | Acc]);
sub_chars1([H | T], Acc) ->
	sub_chars1(T, [H | Acc]);
sub_chars1([], Acc) ->
	lists:reverse(Acc).

-spec directory_path(Path, ConfigDb) -> Result
	when
		Path :: string(),
		ConfigDb :: term(),
		Result :: {ok, {Directory, DirectoryData}} | {error, Reason},
		Directory :: string(),
		DirectoryData :: list(),
		Reason :: invalid.
%% @doc Look up the configuration directory.
directory_path(Path, ConfigDB)
		when is_list(Path) ->
	Directories = ets:match(ConfigDB,{directory, {'$1','_'}}),
	case path_check(Path, lists:usort(Directories)) of
		{ok, Directory} ->
			{ok, {Directory, lists:flatten(ets:match(ConfigDB,
					{directory, {Directory,'$1'}}))}};
		{error, Reason} ->
			{error, Reason}
	end.

%% @hidden
path_check(_Path, []) ->
	{error, invalid};
path_check(Path, Directories) ->
	List = convert(Path, Directories, []),
	F = fun(A, B)
			when length(A) > length(B) ->
			true;
		(_A, _B) ->
			false
	end,
	[{_, Directory} | _] = lists:sort(F, List),
	{ok, Directory}.

%% @hidden
convert(Path,[[H] | T], Acc) ->
	convert(Path, T, [{Path, H} | Acc]);
convert(Path, [], Acc) ->
	[{Path, []} | Acc].

-spec struct_to_map(Struct) -> Map
	when
		Struct :: {struct, [tuple()]},
		Map :: map().
%% @doc Convert mochijson struct to a map.
struct_to_map({struct, List}) ->
	struct_to_map(List, #{}).

struct_to_map([{Name, {array, Value}} | T ], Acc) ->
	struct_to_map(T, Acc#{Name => Value});
struct_to_map([{Name, Value} | T ], Acc) ->
	struct_to_map(T, Acc#{Name => Value});
struct_to_map([], Acc) ->
	Acc.

%% @hidden
send(#mod{socket = Socket, socket_type = SocketType} = Info,
		StatusCode, Headers, ResponseBody) ->
	httpd_response:send_header(Info, StatusCode, Headers),
	httpd_socket:deliver(SocketType, Socket, ResponseBody).

