%% @author Marc Worrell <marc@worrell.nl>
%% @copyright 2009-2020 Marc Worrell
%%
%% @doc Mailinglist model.

%% Copyright 2009-2020 Marc Worrell
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

-module(m_mailinglist).
-author("Marc Worrell <marc@worrell.nl").

-behaviour(zotonic_model).

%% interface functions
-export([
    m_get/3,

    get_stats/2,
    get_enabled_recipients/2,
    list_recipients/2,
    count_recipients/2,
    insert_recipients/4,
    insert_recipient/4,
    insert_recipient/5,

    update_recipient/3,

    recipient_get/2,
    recipient_get/3,
    recipient_delete/2,
    recipient_delete/3,
    recipient_delete_quiet/2,
    recipient_confirm/2,
    recipient_is_enabled_toggle/2,
    recipients_clear/2,

    insert_scheduled/3,
    delete_scheduled/3,
    get_scheduled/2,
    check_scheduled/1,

    get_email_from/2,
    get_recipients_by_email/2,
    reset_log_email/3,

    recipient_set_operation/4,

    normalize_email/1,

    periodic_cleanup/1
]).

-include_lib("zotonic_core/include/zotonic.hrl").


%% @doc Fetch the value for the key from a model source
-spec m_get( list(), zotonic_model:opt_msg(), z:context() ) -> zotonic_model:return().
m_get([ <<"stats">>, MailingId | Rest ], _Msg, Context) ->
    case z_acl:rsc_editable(MailingId, Context) of
        true -> {ok, {get_stats(MailingId, Context), Rest}};
        false -> {ok, {{undefined, undefined}, Rest}}
    end;
m_get([ <<"rsc_stats">>, RscId | Rest ], _Msg, Context) ->
    case z_acl:is_allowed(use, mod_mailinglist, Context) of
        true -> {ok, {get_rsc_stats(RscId, Context), Rest}};
        false -> {error, eacces}
    end;
m_get([ <<"recipient">>, RecipientId | Rest ], _Msg, Context) ->
    case z_acl:is_allowed(use, mod_mailinglist, Context) of
        true -> {ok, {recipient_get(z_convert:to_integer(RecipientId), Context), Rest}};
        false -> {error, eacces}
    end;
m_get([ <<"scheduled">>, RscId | Rest ], _Msg, Context) ->
    case z_acl:rsc_visible(RscId, Context) of
        true -> {ok, {get_scheduled(RscId, Context), Rest}};
        false -> {error, eacces}
    end;
m_get([ <<"confirm_key">>, ConfirmKey | Rest ], _Msg, Context) ->
    {ok, {get_confirm_key(ConfirmKey, Context), Rest}};
m_get([ <<"subscription">>, ListId, Email | Rest ], _Msg, Context) ->
    case z_acl:is_allowed(use, mod_mailinglist, Context) of
        true -> {ok, {recipient_get(ListId, Email, Context), Rest}};
        false -> {error, eacces}
    end;
m_get(_Vs, _Msg, _Context) ->
    {error, unknown_path}.


%% @doc Get the stats for the mailing. Number of recipients and list of scheduled resources.
-spec get_stats( m_rsc:resource_id(), z:contex() ) -> map().
get_stats(ListId, Context) ->
    Counts = z_mailinglist_recipients:count_recipients(ListId, Context),
    Scheduled = z_db:q("
        select page_id
        from mailinglist_scheduled
                join rsc on id = page_id
        where mailinglist_id = $1
        order by publication_start", [ListId], Context),
    Counts#{
        scheduled => Scheduled
    }.


%% @doc Get the stats for all mailing lists which have been sent to a rsc (content_id)
-spec get_rsc_stats( m_rsc:resource_id(), z:context() ) -> [ {ListId::m_rsc:resource_id(), Statuslist} ]
    when Statuslist :: list( binary() ).
get_rsc_stats(Id, Context) ->
    F = fun() ->
        RsLog = z_db:q("
            select other_id, min(created) as sent_on, count(distinct(envelop_to))
            from log_email
            where content_id = $1
            group by other_id",
            [Id],
            Context),

        Stats = lists:map(
                    fun({ListId, Created, Total}) ->
                        {ListId, [{created, Created}, {total, Total}]}
                    end,
                    RsLog),
        %% merge in all mailer statuses
        PerStatus = z_db:q("
            select other_id, mailer_status, count(envelop_to)
            from log_email
            where content_id = $1
            group by other_id, mailer_status",
            [Id],
            Context),

        lists:foldl(
            fun({ListId, Status, Count}, St) ->
                z_utils:prop_replace(ListId,
                                     [{z_convert:to_atom(Status), Count}|proplists:get_value(ListId, St, [])],
                                     St)
            end,
            Stats,
            PerStatus)
    end,
    z_depcache:memo(F, {mailinglist_stats, Id}, 1, [Id], Context). %% Cache a little while to prevent database DOS while mail is sending



%% @doc Fetch all enabled recipients from a list.
-spec get_enabled_recipients( m_rsc:resource_id(), z:context() ) -> list( binary() ).
get_enabled_recipients(ListId, Context) ->
    Emails = z_db:q("
        select email
        from mailinglist_recipient
        where mailinglist_id = $1
          and is_enabled = true", [ z_convert:to_integer(ListId) ], Context),
    [ E || {E} <- Emails ].


%% @doc List all recipients of a mailinglist (as maps with binary keys, props expanded)
-spec list_recipients( m_rsc:resource_id(), z:context() ) -> {ok, list( map() )} | {error, term()}.
list_recipients(ListId, Context) ->
    z_db:qmap_props("
        select *
        from mailinglist_recipient
        where mailinglist_id = $1",
        [ z_convert:to_integer(ListId) ], Context).

-spec count_recipients( m_rsc:resource_id(), z:context() ) -> non_neg_integer().
count_recipients(ListId, Context) ->
    z_db:q1("
            select count(*)
            from mailinglist_recipient
            where mailinglist_id = $1",
            [ z_convert:to_integer(ListId) ],
            Context).


%% @doc Toggle the enabled flag of a recipient
recipient_is_enabled_toggle(RecipientId, Context) ->
    case z_db:q("
            update mailinglist_recipient
            set is_enabled = not is_enabled
            where id = $1", [ z_convert:to_integer(RecipientId) ], Context)
    of
        1 -> ok;
        0 -> {error, enoent}
    end.

%% @doc Fetch the recipient record for the recipient id.
recipient_get(RecipientId, Context) ->
    z_db:assoc_row("
        select *
        from mailinglist_recipient
        where id = $1",
        [ z_convert:to_integer(RecipientId) ],
        Context).

%% @doc Fetch the recipient record by e-mail address
recipient_get(undefined, _Email, _Context) ->
    undefined;
recipient_get(<<>>, _Email, _Context) ->
    undefined;
recipient_get(ListId, Email, Context) ->
    Email1 = normalize_email(Email),
    z_db:assoc_row("
        select * from mailinglist_recipient
        where mailinglist_id = $1
          and email = $2",
        [ z_convert:to_integer(ListId), z_convert:to_binary(Email1) ], Context).


%% @doc Delete a recipient without sending the recipient a goodbye e-mail.
recipient_delete_quiet(RecipientId, Context) ->
    case recipient_get(RecipientId, Context) of
        undefined -> {error, enoent};
        RecipientProps -> recipient_delete1(RecipientProps, true, Context)
    end.

%% @doc Delete a recipient and send the recipient a goodbye e-mail.
recipient_delete(RecipientId, Context) ->
    case recipient_get(RecipientId, Context) of
        undefined -> {error, enoent};
        RecipientProps -> recipient_delete1(RecipientProps, false, Context)
    end.

%% @doc Delete a recipient by list id and email
recipient_delete(ListId, Email, Context) ->
    case recipient_get(ListId, Email, Context) of
        undefined -> {error, enoent};
        RecipientProps -> recipient_delete1(RecipientProps, false, Context)
    end.

recipient_delete1(RecipientProps, Quiet, Context) ->
    RecipientId = proplists:get_value(id, RecipientProps),
    z_db:delete(mailinglist_recipient, RecipientId, Context),
    ListId = proplists:get_value(mailinglist_id, RecipientProps),
    case Quiet of
        false ->
            z_notifier:notify1(#mailinglist_message{what=send_goodbye, list_id=ListId, recipient=RecipientProps}, Context);
        _ -> nop
    end,
    ok.

%% @doc Confirm the recipient with the given unique confirmation key.
-spec recipient_confirm( binary(), z:context() ) -> {ok, m_rsc:resource_id()} | {error, term()}.
recipient_confirm(ConfirmKey, Context) ->
    case z_db:q_row("select id, is_enabled, mailinglist_id from mailinglist_recipient where confirm_key = $1", [ConfirmKey], Context) of
        {RecipientId, _IsEnabled, ListId} ->
            NewConfirmKey = z_ids:id(20),
            z_db:q("update mailinglist_recipient set confirm_key = $2, is_enabled = true where confirm_key = $1", [ConfirmKey, NewConfirmKey], Context),
            z_notifier:notify(#mailinglist_message{what=send_welcome, list_id=ListId, recipient=RecipientId}, Context),
            {ok, RecipientId};
        undefined ->
            {error, enoent}
    end.

%% @doc Clear all recipients of the list
-spec recipients_clear( m_rsc:resource_id(), z:context() ) -> ok.
recipients_clear(ListId, Context) ->
    %% TODO clear person edges to list
    z_db:q("delete from mailinglist_recipient where mailinglist_id = $1", [ListId], Context),
    ok.

%% @doc Fetch the information for a confirmation key
-spec get_confirm_key( binary(), z:context() ) -> proplists:proplist() | undefined.
get_confirm_key(ConfirmKey, Context) ->
    z_db:assoc_row("select id, mailinglist_id, email, confirm_key from mailinglist_recipient where confirm_key = $1", [ConfirmKey], Context).


%% @doc Insert a recipient in the mailing list, send a message to the recipient when needed.
insert_recipient(ListId, Email, WelcomeMessageType, Context) ->
    insert_recipient(ListId, Email, [], WelcomeMessageType, Context).

insert_recipient(ListId, Email, Props, WelcomeMessageType, Context) ->
    case z_acl:rsc_visible(ListId, Context) of
        false ->
            {error, eacces};
        true ->
            Email1 = normalize_email(Email),
            Rec = z_db:q_row("select id, is_enabled, confirm_key
                              from mailinglist_recipient
                              where mailinglist_id = $1
                                and email = $2", [ListId, Email1], Context),
            ConfirmKey = binary_to_list(z_ids:id(20)),
            {RecipientId, WelcomeMessageType1} = case Rec of
                {RcptId, true, _OldConfirmKey} ->
                    %% Present and enabled
                    {RcptId, silent};
                {RcptId, false, OldConfirmKey} ->
                    %% Present, but not enabled
                    NewConfirmKey = case OldConfirmKey of
                        undefined -> ConfirmKey;
                        _ -> OldConfirmKey
                    end,
                    case WelcomeMessageType of
                        send_confirm ->
                            case NewConfirmKey of
                                OldConfirmKey -> nop;
                                _ -> z_db:q("update mailinglist_recipient
                                             set confirm_key = $2
                                             where id = $1", [RcptId, NewConfirmKey], Context)
                            end,
                            {RcptId, {send_confirm, NewConfirmKey}};
                        _ ->
                            z_db:q("update mailinglist_recipient
                                    set is_enabled = true,
                                        confirm_key = $2
                                    where id = $1", [RcptId, NewConfirmKey], Context),
                            {RcptId, WelcomeMessageType}
                    end;
                undefined ->
                    %% Not present
                    IsEnabled = case WelcomeMessageType of
                        send_welcome -> true;
                        send_confirm -> false;
                        silent -> true
                    end,
                    Cols = [
                        {mailinglist_id, ListId},
                        {is_enabled, IsEnabled},
                        {email, Email1},
                        {confirm_key, ConfirmKey}
                    ] ++ [ {K, case is_list(V) of true-> z_convert:to_binary(V); false -> V end} || {K,V} <- Props ],
                    {ok, RcptId} = z_db:insert(mailinglist_recipient, Cols, Context),
                    {RcptId, WelcomeMessageType}
            end,
            case WelcomeMessageType1 of
                none -> nop;
                _ -> z_notifier:notify(
                        #mailinglist_message{
                            what = WelcomeMessageType1,
                            list_id = ListId,
                            recipient = RecipientId
                        }, Context)
            end,
            ok
    end.


%% @doc Update a single recipient; changing e-mail address or name details.
update_recipient(RcptId, Props, Context) ->
    {ok, _} = z_db:update(mailinglist_recipient, RcptId, Props, Context),
    ok.


%% @doc Replace all recipients of the mailinglist. Do not send welcome messages to the recipients.
-spec insert_recipients(ListId::m_rsc:resource_id(), Recipients::list( binary()|string() ) | binary(), IsTruncate::boolean(), z:context()) ->
    ok | {error, term()}.
insert_recipients(ListId, Bin, IsTruncate, Context) when is_binary(Bin) ->
    Lines = z_string:split_lines(Bin),
    Rcpts = lines_to_recipients(Lines),
    insert_recipients(ListId, Rcpts, IsTruncate, Context);
insert_recipients(ListId, Recipients, IsTruncate, Context) ->
    case z_acl:rsc_editable(ListId, Context) of
        true ->
            ok = z_db:transaction(
                            fun(Ctx) ->
                                {ok, Now} = insert_recipients1(ListId, Recipients, Ctx),
                                optional_truncate(ListId, IsTruncate, Now, Ctx)
                            end, Context);
        false ->
            {error, eacces}
    end.

    insert_recipients1(ListId, Recipients, Context) ->
        Now = erlang:universaltime(),
        [ replace_recipient(ListId, R, Now, Context) || R <- Recipients ],
        {ok, Now}.

    optional_truncate(_, false, _, _) ->
        ok;
    optional_truncate(ListId, true, Now, Context) ->
        z_db:q("
            delete from mailinglist_recipient
            where mailinglist_id = $1
              and timestamp < $2", [ListId, Now], Context),
        ok.

replace_recipient(ListId, Recipient, Now, Context) when is_binary(Recipient) ->
    replace_recipient(ListId, Recipient, [], Now, Context);
replace_recipient(ListId, Recipient, Now, Context) ->
    replace_recipient(ListId, proplists:get_value(email, Recipient), proplists:delete(email, Recipient), Now, Context).


replace_recipient(ListId, Email, Props, Now, Context) ->
    case normalize_email(Email) of
        <<>> ->
            skip;
        Email1 ->
            case z_db:q1("select id from mailinglist_recipient where mailinglist_id = $1 and email = $2",
                         [ListId, Email1], Context) of
                undefined ->
                    ConfirmKey = z_ids:id(20),
                    Props1 = [{confirm_key, ConfirmKey},
                              {email, Email1},
                              {timestamp, Now},
                              {mailinglist_id, ListId},
                              {is_enabled, true}] ++ Props,
                    z_db:insert(mailinglist_recipient, Props1, Context);
                EmailId ->
                    z_db:update(mailinglist_recipient, EmailId, [{timestamp, Now}, {is_enabled, true}] ++ Props, Context)
            end
    end.


lines_to_recipients(Lines) ->
    lines_to_recipients(Lines, []).
lines_to_recipients([], Acc) -> Acc;
lines_to_recipients([Line|Lines], Acc) ->
    %% Split every line on tab
    Trimmed = z_string:trim( z_convert:to_binary(Line) ),
    case z_csv_parser:parse_line(Trimmed, 9) of
        {ok, [<<>>]} ->
            lines_to_recipients(Lines, Acc);
        {ok, Row} ->
            R = line_to_recipient(Row),
            lines_to_recipients(Lines, [R|Acc])
    end.

line_to_recipient([ Email ]) ->
    [ {email, Email} ];
line_to_recipient([ Email, NameFirst ]) ->
    [
        {email, Email},
        {name_first, NameFirst}
    ];
line_to_recipient([ Email, NameFirst, NameLast ]) ->
    [
        {email, Email},
        {name_first, NameFirst},
        {name_surname, NameLast}
    ];
line_to_recipient([ Email, NameFirst, NameLast, NamePrefix | _ ]) ->
    [
        {email, Email},
        {name_first, NameFirst},
        {name_surname, NameLast},
        {name_surname_prefix, NamePrefix}
    ].

%% @doc Insert a mailing to be send when the page becomes visible
insert_scheduled(ListId, PageId, Context) ->
    true = z_acl:rsc_editable(ListId, Context),
    Exists = z_db:q1("
                select count(*)
                from mailinglist_scheduled
                where page_id = $1 and mailinglist_id = $2", [PageId,ListId], Context),
    case Exists of
        0 ->
           z_mqtt:publish(
                [ <<"model">>, <<"mailinglist">>, <<"event">>, ListId, <<"scheduled">> ],
                #{ id => ListId, page_id => PageId, action => <<"insert">> },
                Context),
            z_db:q("insert into mailinglist_scheduled (page_id, mailinglist_id) values ($1,$2)",
                    [PageId, ListId], Context);
        1 ->
            nop
    end.

%% @doc Delete a scheduled mailing
delete_scheduled(ListId, PageId, Context) ->
    true = z_acl:rsc_editable(ListId, Context),
    case z_db:q("
            delete from mailinglist_scheduled
            where page_id = $1
              and mailinglist_id = $2",
            [PageId,ListId],
            Context)
    of
        0 ->
            0;
        N when N > 0 ->
            z_mqtt:publish(
                [ <<"model">>, <<"mailinglist">>, <<"event">>, ListId, <<"scheduled">> ],
                #{ id => ListId, page_id => PageId, action => <<"delete">> },
                Context),
            N
    end.


%% @doc Get the list of scheduled mailings for a page.
get_scheduled(Id, Context) ->
    Lists = z_db:q("
        select mailinglist_id
        from mailinglist_scheduled
        where page_id = $1", [Id], Context),
    [ ListId || {ListId} <- Lists ].


%% @doc Fetch the next scheduled mailing that are published and in the publication date range.
check_scheduled(Context) ->
    z_db:q_row("
        select m.mailinglist_id, m.page_id
        from mailinglist_scheduled m
        where (
            select r.is_published
               and r.publication_start <= now()
               and r.publication_end >= now()
            from rsc r
            where r.id = m.mailinglist_id
        )
        limit 1", Context).


%% @doc Reset the email log for given list/page combination, allowing one to send the same page again to the given list.
reset_log_email(ListId, PageId, Context) ->
    z_db:q("delete from log_email where other_id = $1 and content_id = $2", [ListId, PageId], Context),
    z_depcache:flush({mailinglist_stats, PageId}, Context),
    z_mqtt:publish(
        [ <<"model">>, <<"mailinglist">>, <<"event">>, ListId, <<"scheduled">> ],
        #{ id => ListId, page_id => PageId, action => <<"reset">> },
        Context),
    ok.


%% @doc Get the "from" address used for this mailing list. Looks first in the mailinglist rsc for a ' mailinglist_reply_to' field; falls back to site.email_from config variable.
get_email_from(ListId, Context) ->
    FromEmail = case m_rsc:p(ListId, mailinglist_reply_to, Context) of
                    Empty when Empty =:= undefined; Empty =:= <<>> ->
                        z_convert:to_list(m_config:get_value(site, email_from, Context));
                    RT ->
                        z_convert:to_list(RT)
                end,
    FromName = case m_rsc:p(ListId, mailinglist_sender_name, Context) of
                  undefined -> [];
                  <<>> -> [];
                  SenderName -> z_convert:to_list(SenderName)
               end,
    z_email:combine_name_email(FromName, FromEmail).



%% @doc Get all recipients with this email address.
get_recipients_by_email(Email, Context) ->
    Email1 = normalize_email(Email),
    [ Id || {Id} <- z_db:q("SELECT id FROM mailinglist_recipient WHERE email = $1", [Email1], Context) ].


%% @doc Perform a set operation on two lists. The result of the
%% operation gets stored in the first list.
recipient_set_operation(Op, IdA, IdB, Context) when Op =:= union; Op =:= subtract; Op =:= intersection ->
    A = get_email_set(IdA, Context),
    B = get_email_set(IdB, Context),
    Emails = sets:to_list(sets:Op(A, B)),
    insert_recipients(IdA, Emails, true, Context).


get_email_set(ListId, Context) ->
    Es = z_db:q("
        SELECT email
        FROM mailinglist_recipient
        WHERE mailinglist_id = $1", [ListId], Context),
    Normalized = lists:map(
        fun(E) -> normalize_email(E) end,
        Es),
    sets:from_list(Normalized).

normalize_email(Email) ->
    z_convert:to_binary( z_string:trim( z_string:to_lower( Email ) ) ).



%% @doc Periodically remove bouncing and disabled addresses from the mailinglist
-spec periodic_cleanup(z:context()) -> ok.
periodic_cleanup(Context) ->
    % Remove disabled entries that were not updated for more than 3 months
    z_db:q("
        delete from mailinglist_recipient
        where not is_enabled
          and timestamp < now() - interval '3 months'",
        Context),
    % Remove entries that are invalid, blocked or bouncing
    MaybeBouncing = z_db:q("
        select r.email
        from mailinglist_recipient r
             join email_status s
             on r.email = s.email
        where s.modified < now() - interval '3 months'
            and (  not s.is_valid
                or s.is_blocked
                or s.bounce >= s.modified
                or s.error >= s.modified)
        ",
        Context,
        300000),
    Invalid = lists:filter(
        fun({Email}) ->
            m_email_status:is_ok_to_send(Email, Context)
        end,
        MaybeBouncing),
    z_db:transaction(
        fun(Ctx) ->
            lists:foreach(
                fun({Email}) ->
                    z_db:q("
                        delete from mailinglist_recipient
                        where email = $1",
                        [Email],
                        Ctx)
                end,
                Invalid)
        end,
        Context).
