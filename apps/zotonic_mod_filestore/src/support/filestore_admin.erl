%% @author Marc Worrell <marc@worrell.nl>
%% @copyright 2014 Marc Worrell
%% @doc Event handling for the filestore admin functions

%% Copyright 2014 Marc Worrell
%%
%% Licensed under the Apache License, Version 2.0 (the "License");
%% you may not use this file except in compliance with the License.
%% You may obtain a copy of the License at
%%
%%     http://www.apache.org/licenses/LICENSE-2.0
%%
%% Unless required by applicable law or agreed to in writing, software
%% distributed under the License is distributed on an "AS IS" BASIS,
%% WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
%% See the License for the specific language governing permissions and
%% limitations under the License.

-module(filestore_admin).

-export([
    event/2,
    task_file_to_local/1,
    task_file_to_remote/1
    ]).

-include_lib("zotonic_core/include/zotonic.hrl").

-define(BATCH_MOVE, 100).

event(#submit{message=admin_filestore}, Context) ->
    case z_acl:is_allowed(use, mod_admin_config, Context) of
        true ->
            S3Url = noslash(z_string:trim(z_context:get_q(<<"s3url">>, Context))),
            S3Key = z_string:trim(z_context:get_q(<<"s3key">>, Context)),
            S3Secret = z_string:trim(z_context:get_q(<<"s3secret">>, Context)),
            IsUploadEnabled = z_convert:to_bool(z_context:get_q(<<"is_upload_enabled">>, Context)),
            IsCreateBucket = z_convert:to_bool(z_context:get_q(is_create_bucket, Context)),
            DeleteInterval = z_context:get_q(<<"delete_interval">>, Context),
            case testcred(S3Url, S3Key, S3Secret, IsCreateBucket) of
                ok ->
                    m_config:set_value(mod_filestore, s3url, S3Url, Context),
                    m_config:set_value(mod_filestore, s3key, S3Key, Context),
                    m_config:set_value(mod_filestore, s3secret, S3Secret, Context),
                    m_config:set_value(mod_filestore, is_upload_enabled, IsUploadEnabled, Context),
                    m_config:set_value(mod_filestore, delete_interval, DeleteInterval, Context),
                    z_render:wire([
                            {hide, [{target, "s3error"}]},
                            {hide, [{target, "s3error-queue"}]},
                            {fade_in, [{target, "s3ok"}]}
                        ], Context);
                {error, _} ->
                    z_render:wire([
                            {hide, [{target, "s3ok"}]},
                            {fade_in, [{target, "s3error"}]}
                        ], Context)
            end;
        false ->
            z_render:growl_error(?__("You are not allowed to change these settings.", Context), Context)
    end;
event(#postback{message={admin_filestore_queue, [{is_to_local, true}]}}, Context) ->
    case z_acl:is_allowed(use, mod_admin_config, Context) of
        true ->
            queue_local_all(Context);
        false ->
            z_render:growl_error(?__("You are not allowed to change these settings.", Context), Context)
    end;
event(#postback{message={admin_filestore_queue, [{is_to_cloud, true}]}}, Context) ->
    case z_acl:is_allowed(use, mod_admin_config, Context) of
        true ->
            queue_upload_all(Context);
        false ->
            z_render:growl_error(?__("You are not allowed to change these settings.", Context), Context)
    end.

-define(DATA, <<"Geen wolkje aan de lucht.">>).

% Try a put, get, and delete sequence
testcred(S3Url, S3Key, S3Secret, IsCreateBucket)
    when is_binary(S3Url), is_binary(S3Key), is_binary(S3Secret) ->
    case testcred_file(S3Url, S3Key, S3Secret) of
        ok ->
            ok;
        {error, enoent} when IsCreateBucket ->
            % Bucket might not exist, try creating it
            Cred = {S3Key, S3Secret},
            case s3filez:create_bucket(Cred, S3Url) of
                ok ->
                    testcred_file(S3Url, S3Key, S3Secret);
                {error, Reason} = Error ->
                    ?LOG_ERROR(#{
                        text => <<"S3 could not create bucket">>,
                        in => zotonic_mod_filestore,
                        result => error,
                        reason => Reason,
                        url => S3Url
                    }),
                    Error
            end;
        {error, _} = Error ->
            Error
    end.

testcred_file(S3Url, S3Key, S3Secret)
    when is_binary(S3Url), is_binary(S3Key), is_binary(S3Secret) ->
    Cred = {S3Key, S3Secret},
    Url = <<S3Url/binary, $/, "-zotonic-filestore-test-file-">>,
    Data = iolist_to_binary([?DATA, " ", z_ids:identifier()]),
    case s3filez:put(Cred, Url, {data, Data}) of
        ok ->
            case s3filez:get(Cred, Url) of
                {ok, _Mime, Data} ->
                    s3filez:delete(Cred, Url);
                {ok, Mime, OtherData} ->
                    ?LOG_WARNING(#{
                        text => <<"S3 get error, non matching data">>,
                        in => zotonic_mod_filestore,
                        result => error,
                        reason => data,
                        mime_received => Mime,
                        data_received => OtherData,
                        data_expected => Data,
                        url => Url
                    }),
                    {error, data};
                {error, Reason} = Error ->
                    ?LOG_WARNING(#{
                        text => <<"S3 get error">>,
                        in => zotonic_mod_filestore,
                        result => error,
                        reason => Reason,
                        url => Url
                    }),
                    Error
            end;
        {error, Reason} = Error ->
            ?LOG_WARNING(#{
                text => <<"S3 put error">>,
                in => zotonic_mod_filestore,
                result => error,
                reason => Reason,
                url => Url
            }),
            Error
    end;
testcred_file(_, _, _) ->
    {error, filestore_unconfigured}.


noslash(<<>>) ->
    <<>>;
noslash(B) ->
    case binary:last(B) of
        $/ ->
            noslash(binary:part(B, 0, size(B)-1));
        _ ->
            B
    end.


queue_upload_all(Context) ->
    S3Url = m_config:get_value(mod_filestore, s3url, Context),
    S3Key = m_config:get_value(mod_filestore, s3key, Context),
    S3Secret = m_config:get_value(mod_filestore, s3secret, Context),
    case testcred_file(S3Url, S3Key, S3Secret) of
        ok ->
            mod_filestore:queue_all(Context),
            z_pivot_rsc:delete_task(?MODULE, task_file_to_local, <<>>, Context),
            z_pivot_rsc:insert_task_after(5, ?MODULE, task_file_to_remote, <<>>, [], Context),
            QueueCt = z_db:q1("select count(*) from filestore_queue", Context),
            z_render:wire([
                    {update, [{target, "s3queue"}, {text, z_convert:to_binary(QueueCt)}]},
                    {hide, [{target, "s3error-queue"}]},
                    {hide, [{target, "s3ok-queue-local"}]},
                    {fade_in, [{target, "s3ok-queue"}]}
                ], Context);
        {error, _} ->
            z_render:wire([
                    {hide, [{target, "s3ok-queue"}]},
                    {hide, [{target, "s3ok-queue-local"}]},
                    {fade_in, [{target, "s3error-queue"}]}
                ], Context)
    end.

queue_local_all(Context) ->
    mod_filestore:queue_all_stop(Context),
    z_pivot_rsc:delete_task(?MODULE, task_file_to_remote, <<>>, Context),
    z_pivot_rsc:insert_task_after(5, ?MODULE, task_file_to_local, <<>>, [], Context),
    QueueCt = z_db:q1("select count(*) from filestore where is_move_to_local and not is_deleted", Context),
    z_render:wire([
            {update, [{target, "s3queue-local"}, {text, z_convert:to_binary(QueueCt)}]},
            {hide, [{target, "s3error-queue"}]},
            {hide, [{target, "s3ok-queue"}]},
            {fade_in, [{target, "s3ok-queue-local"}]}
        ], Context).


task_file_to_local(Context) ->
    case catch m_filestore:mark_move_to_local_limit(?BATCH_MOVE, Context) of
        {ok, 0} ->
            ok;
        {ok, N} ->
            ?LOG_NOTICE(#{
                text => <<"Marked files for move to local">>,
                in => zotonic_mod_filestore,
                result => ok,
                count => N
            }),
            {delay, 1};
        _Other ->
            {delay, 10}
    end.

task_file_to_remote(Context) ->
    case catch m_filestore:unmark_move_to_local_limit(?BATCH_MOVE, Context) of
        {ok, 0} ->
            ok;
        {ok, N} ->
            ?LOG_NOTICE(#{
                text => <<"Unmarked files for move to local">>,
                in => zotonic_mod_filestore,
                result => ok,
                count => N
            }),
            {delay, 1};
        _Other ->
            {delay, 10}
    end.
