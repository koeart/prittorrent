-module(model_enclosures).

-export([to_hash/0, set_torrent/3, item_torrents/2,
	 recent_downloads/0, popular_downloads/0,
	 user_downloads/1, feed_downloads/1]).

-include("../include/model.hrl").

-define(POOL, pool_users).
-define(Q(Stmt, Params), model_sup:equery(?POOL, Stmt, Params)).
-define(T(Fun), model_sup:transaction(?POOL, Fun)).

to_hash() ->
    case ?Q("SELECT \"enclosure_url\" FROM enclosure_to_hash()", []) of
	{ok, _, [{URL}]}
	  when is_binary(URL),
	       size(URL) > 0 ->
	    {ok, URL};
	{ok, _, [{null}]} ->
	    nothing
    end.

set_torrent(URL, Error, InfoHash) ->
    ?T(fun(Q) ->
	       case Q("SELECT count(\"url\") FROM enclosure_torrents WHERE \"url\"=$1", [URL]) of
		   {ok, _, [{0}]} ->
		       Q("INSERT INTO enclosure_torrents (\"url\", \"last_update\", \"info_hash\", \"error\") VALUES ($1, CURRENT_TIMESTAMP, $2, $3)", [URL, InfoHash, Error]);
		   {ok, _, [{1}]} ->
		       Q("UPDATE enclosure_torrents SET \"last_update\"=CURRENT_TIMESTAMP, \"info_hash\"=$2, \"error\"=$3 WHERE \"url\"=$1", [URL, InfoHash, Error])
	       end
       end).

%% TODO: rm, expensive view
item_torrents(Feed, Item) ->
    {ok, _, Torrents} =
	?Q("SELECT \"url\", \"info_hash\" FROM item_torrents WHERE \"feed\"=$1 AND \"item\"=$2 ORDER BY \"url\"", [Feed, Item]),
    Torrents.

recent_downloads() ->
    query_downloads("TRUE", [],
		    "\"published\" DESC", 42).

popular_downloads() ->
    query_downloads("(\"seeders\" + \"leechers\") > 0", [],
		    "(\"seeders\" + \"leechers\") DESC", 23).

user_downloads(UserName) ->
    query_downloads("\"feed\" IN (SELECT \"feed\" FROM user_feeds WHERE \"user\"=$1)", [UserName],
		    "\"published\" DESC", 23).

feed_downloads(Feed) ->
    query_downloads("\"feed\"=$1", [Feed],
		    "\"published\" DESC", 50).

query_downloads(Cond, Params, Order, Limit) ->
    case ?Q("SELECT \"user\", \"slug\", \"feed\", \"item\", \"enclosure\", \"info_hash\", \"name\", \"size\", \"title\", \"published\", \"homepage\", \"payment\", \"image\", \"seeders\", \"leechers\", \"upspeed\", \"downspeed\" FROM downloads_scraped WHERE " ++ Cond ++ " ORDER BY " ++ Order ++ " LIMIT " ++ integer_to_list(Limit), Params) of
	{ok, _, Rows} ->
	    Downloads =
		rows_to_downloads(Rows),
	    FeedItems = group_downloads(Downloads),
	    {ok, FeedItems};
	{error, Reason} ->
	    {error, Reason}
    end.

rows_to_downloads(Rows) ->
    [#download{user = User,
	       slug = Slug,
	       feed = Feed,
	       item = Item,
	       enclosure = Enclosure,
	       info_hash = InfoHash,
	       name = Name,
	       size = Size,
	       title = Title,
	       published = Published,
	       homepage = Homepage,
	       payment = Payment,
	       image = Image,
	       seeders = Seeders,
	       leechers = Leechers,
	       upspeed = Upspeed,
	       downspeed = Downspeed}
     || {User, Slug, Feed, Item, Enclosure,
	 InfoHash, Name, Size,
	 Title, Published, Homepage, Payment, Image,
	 Seeders, Leechers, Upspeed, Downspeed
	} <- Rows].

%% By homepage
group_downloads([]) ->
    [];
group_downloads([Download | Downloads]) ->
    #download{user = User,
	      slug = Slug,
	      feed = Feed,
	      item = Item,
	      title = Title,
	      published = Published,
	      homepage = Homepage,
	      payment = Payment,
	      image = Image} = Download,
    {SiblingDownloads, OtherDownloads} =
	lists:splitwith(
	  fun(#download{homepage = Homepage1}) ->
		  Homepage == Homepage1
	  end, Downloads),
    FeedItem =
	#feed_item{user = User,
		   slug = Slug,
		   feed = Feed,
		   id = Item,
		   title = Title,
		   published = Published,
		   homepage = Homepage,
		   payment = Payment,
		   image = Image,
		   %% Duplicate downloads may occur for merged
		   %% feed_items (by homepage):
		   downloads = unique_downloads([Download | SiblingDownloads])
		  },
    [FeedItem | group_downloads(OtherDownloads)].

%% Also sorts by name
unique_downloads(Downloads) ->
    ByName =
	lists:foldl(fun(#download{name = Name} = Download, ByName) ->
			    case gb_trees:is_defined(Name, ByName) of
				false ->
				    gb_trees:insert(Name, Download, ByName);
				true ->
				    %% Drop duplicate
				    ByName
			    end
		    end, gb_trees:empty(), Downloads),
    [Download
     || {_Name, Download} <- gb_trees:to_list(ByName)].
