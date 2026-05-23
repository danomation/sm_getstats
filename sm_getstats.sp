emod/scripting# cat stats_test.sp
#include <sdktools>
#include <sourcemod>
#include <ripext>

enum struct MatchEntry {
    char name[64];
    int userid;
    float rating;
    float vorp;
    int grank;
}

ArrayList g_MatchResults;
int g_PendingRequests;
int g_MatchClient;
bool g_IsBalancing;
int g_VoteCooldown = 0;
bool g_JustBalanced[MAXPLAYERS + 1] = { false, ... };

#define TEAM_SPECTATOR 1
#define TEAM_PUNK 2
#define TEAM_CORPS 3

public Plugin myinfo = {
    name = "Custom stats - team balancer",
    author = "alpha",
    description = "Gets player stats and balances players",
    version = "2.1",
    url = ""
}

public void OnPluginStart() {
    HookEvent("player_spawn", Event_PlayerSpawn);
    RegConsoleCmd("sm_getstats", Command_GetStats);
    RegConsoleCmd("sm_getmatch", Command_GetMatch);
    RegConsoleCmd("sm_balance", Command_Balance, "Vote to balance teams by rating");
    RegAdminCmd("sm_forcebalance", Command_ForceBalance, ADMFLAG_GENERIC, "Force balance teams by rating");
}

public Action Command_GetStats(int client, int args) {
    char steamid[32];
    if (args > 0) {
        GetCmdArg(1, steamid, sizeof(steamid));
    } else {
        GetClientAuthId(client, AuthId_SteamID64, steamid, sizeof(steamid));
    }

    PrintToChat(client, "Getting stats for: %s", steamid);

    char url[256];
    Format(url, sizeof(url), "https://dys-stats.cartesianbear.com/data/player/%s", steamid);

    HTTPRequest request = new HTTPRequest(url);
    request.SetHeader("User-Agent", "SourceMod-Stats/1.0");
    request.Get(OnStatsReceived, GetClientUserId(client));

    return Plugin_Handled;
}

public Action Command_GetMatch(int client, int args) {
    g_IsBalancing = false;
    FetchAllPlayers(client);
    return Plugin_Handled;
}

public Action Command_Balance(int client, int args) {
    if (IsVoteInProgress()) {
        PrintToChat(client, "A vote is already in progress.");
        return Plugin_Handled;
    }

    int currentTime = GetTime();
    if (currentTime < g_VoteCooldown) {
        int remaining = g_VoteCooldown - currentTime;
        PrintToChat(client, "Vote on cooldown. %d:%02d remaining.", remaining / 60, remaining % 60);
        return Plugin_Handled;
    }

    Menu vote = new Menu(VoteBalanceHandler);
    vote.SetTitle("Balance teams by rating?");
    vote.AddItem("yes", "Yes");
    vote.AddItem("no", "No");
    vote.ExitButton = false;
    SetVoteResultCallback(vote, VoteBalanceResults);
    vote.DisplayVoteToAll(30);
    CreateTimer(15.0, Timer_VoteReminder);
    g_MatchClient = GetClientUserId(client);
    g_VoteCooldown = currentTime + 90;

    return Plugin_Handled;
}

public Action Timer_VoteReminder(Handle timer) {
    if (IsVoteInProgress()) {
        PrintToChatAll("Vote ending in 15 seconds! Type !vote to vote.");
    }
    return Plugin_Stop;
}

public void VoteBalanceResults(Menu menu, int num_votes, int num_clients, const int[][] client_info, int num_items, const int[][] item_info) {
    int totalPlayers = 0;
    for (int i = 1; i <= MaxClients; i++) {
        if (IsClientInGame(i) && !IsFakeClient(i)) {
            totalPlayers++;
        }
    }

    int requiredYes = RoundToCeil(totalPlayers / 2.0);

    int yesVotes = 0;
    int noVotes = 0;
    for (int i = 0; i < num_items; i++) {
        if (item_info[i][VOTEINFO_ITEM_INDEX] == 0)
            yesVotes = item_info[i][VOTEINFO_ITEM_VOTES];
        else if (item_info[i][VOTEINFO_ITEM_INDEX] == 1)
            noVotes = item_info[i][VOTEINFO_ITEM_VOTES];
    }

    if (yesVotes >= requiredYes && yesVotes > noVotes) {
        PrintToChatAll("Vote passed! (%d yes, %d no) Balancing teams...", yesVotes, noVotes);
        int client = GetClientOfUserId(g_MatchClient);
        if (client > 0) {
            g_IsBalancing = true;
            FetchAllPlayers(client);
        }
    } else {
        PrintToChatAll("Vote failed. (%d yes, %d no, needed %d yes.)", yesVotes, noVotes, requiredYes);
    }
}

public void Event_PlayerSpawn(Event event, const char[] name, bool dontBroadcast) {
    int client = GetClientOfUserId(event.GetInt("userid"));
    if (client > 0 && g_JustBalanced[client]) {
        g_JustBalanced[client] = false;
        RequestFrame(Frame_KillPlayer, GetClientUserId(client));
    }
}

public void Frame_KillPlayer(any userid) {
    int client = GetClientOfUserId(userid);
    if (client > 0 && IsPlayerAlive(client)) {
        ForcePlayerSuicide(client);
    }
}


public Action Command_ForceBalance(int client, int args) {
    PrintToChatAll("Admin forcing team balance...");
    g_IsBalancing = true;
    g_MatchClient = GetClientUserId(client);
    FetchAllPlayers(client);
    return Plugin_Handled;
}


public int VoteBalanceHandler(Menu menu, MenuAction action, int param1, int param2) {
    if (action == MenuAction_End) {
        delete menu;
    }
    return 0;
}

void FetchAllPlayers(int client) {
    delete g_MatchResults;
    g_MatchResults = new ArrayList(sizeof(MatchEntry));
    g_PendingRequests = 0;
    g_MatchClient = GetClientUserId(client);

    for (int i = 1; i <= MaxClients; i++) {
        if (IsClientInGame(i) && !IsFakeClient(i) && !IsClientSourceTV(i)) {
            int team = GetClientTeam(i);
            if (team < TEAM_PUNK) continue; // skip spectators

            char steamid[32];
            GetClientAuthId(i, AuthId_SteamID64, steamid, sizeof(steamid) - 1);

            char url[256];
            Format(url, sizeof(url), "https://dys-stats.cartesianbear.com/data/player/%s", steamid);

            g_PendingRequests++;

            DataPack pack = new DataPack();
            pack.WriteCell(GetClientUserId(i));
            pack.WriteCell(GetClientUserId(client));

            HTTPRequest request = new HTTPRequest(url);
            request.SetHeader("User-Agent", "SourceMod-Stats/1.0");
            request.Get(OnStatsReceived2, pack);
        }
    }

    if (g_PendingRequests == 0) {
        PrintToChat(client, "No eligible players found.");
    }
}

public void OnStatsReceived(HTTPResponse response, any userid) {
    int client = GetClientOfUserId(userid);
    if (client <= 0) return;

    if (response.Status == HTTPStatus_OK) {
        JSONObject json = view_as<JSONObject>(response.Data);
        if (json != null) {
            JSONObject general = view_as<JSONObject>(json.Get("general"));
            if (general != null) {
                int kills = general.GetInt("kills");
                int deaths = general.GetInt("deaths");
                int points = general.GetInt("points");
                float rating = general.GetFloat("rating");
                float vorp = general.GetFloat("vorp");
                int grank = general.GetInt("grank");

                PrintToChat(client, "Stats: Kills:%d Deaths:%d Points:%d", kills, deaths, points);
                PrintToChat(client, "Rating:%.2f GRank:#%d", rating * 100.0, grank);
                PrintToChat(client, "VORP:%.2f %%", (vorp - 1.0) * 100.0);
                delete general;
            } else {
                PrintToChat(client, "No general stats found");
            }
            delete json;
        }
    } else {
        PrintToChat(client, "HTTP Error: %d", response.Status);
    }
}

public void OnStatsReceived2(HTTPResponse response, DataPack pack) {
    pack.Reset();
    int playerUserId = pack.ReadCell();
    int requesterUserId = pack.ReadCell();
    delete pack;

    g_PendingRequests--;

    MatchEntry entry;
    entry.userid = playerUserId;
    entry.rating = 0.0;
    entry.vorp = 1.0;
    entry.grank = 0;

    int player = GetClientOfUserId(playerUserId);
    if (player > 0 && IsClientInGame(player)) {
        GetClientName(player, entry.name, sizeof(entry.name));
    }

    if (response.Status == HTTPStatus_OK) {
        JSONObject json = view_as<JSONObject>(response.Data);
        if (json != null) {
            JSONObject general = view_as<JSONObject>(json.Get("general"));
            if (general != null) {
                json.GetString("name", entry.name, sizeof(entry.name));
                entry.rating = general.GetFloat("rating");
                entry.vorp = general.GetFloat("vorp");
                entry.grank = general.GetInt("grank");
                delete general;
            }
            delete json;
        }
    }

    g_MatchResults.PushArray(entry);

    if (g_PendingRequests <= 0) {
        g_MatchResults.SortCustom(SortByRating);

        int client = GetClientOfUserId(g_MatchClient);

        if (g_IsBalancing) {
            BalanceTeams(client);
        } else {
            PrintMatchResults(client);
        }
    }
}

void PrintMatchResults(int client) {
    if (client <= 0) return;

    for (int i = 0; i < g_MatchResults.Length; i++) {
        MatchEntry e;
        g_MatchResults.GetArray(i, e);
        PrintToChat(client, "#%d %s | Rating:%.2f | VORP:%.2f%%",
            i + 1, e.name, e.rating * 100.0, (e.vorp - 1.0) * 100.0);
    }
}

void BalanceTeams(int client) {
    int count = g_MatchResults.Length;
    if (count < 2) {
        if (client > 0) PrintToChat(client, "Not enough players to balance.");
        return;
    }

    // Already sorted by rating desc. Greedy: assign each player to the team with lower total.
    float totalPunk = 0.0;
    float totalCorps = 0.0;

    // Arrays to hold team assignments (0 = punk, 1 = corps)
    int[] teamAssign = new int[count];

    for (int i = 0; i < count; i++) {
        MatchEntry e;
        g_MatchResults.GetArray(i, e);

        if (totalPunk <= totalCorps) {
            teamAssign[i] = TEAM_PUNK;
            totalPunk += e.rating;
        } else {
            teamAssign[i] = TEAM_CORPS;
            totalCorps += e.rating;
        }
    }

    // Move players
    for (int i = 0; i < count; i++) {
        MatchEntry e;
        g_MatchResults.GetArray(i, e);

        int player = GetClientOfUserId(e.userid);
        if (player <= 0 || !IsClientInGame(player)) continue;

        int currentTeam = GetClientTeam(player);
        if (currentTeam == teamAssign[i]) continue;

        g_JustBalanced[player] = true;
        ChangeClientTeam(player, teamAssign[i]);
    }

    // Print results
    if (client > 0) {
        PrintToChatAll("--- Teams Balanced ---");
        PrintToChatAll("Punks (%.2f) vs Corps (%.2f)", totalPunk * 100.0, totalCorps * 100.0);

        for (int i = 0; i < count; i++) {
            MatchEntry e;
            g_MatchResults.GetArray(i, e);
            char teamName[16];
            teamName = (teamAssign[i] == TEAM_PUNK) ? "Punk" : "Corps";
            PrintToChatAll("%s -> %s (%.2f)", e.name, teamName, e.rating * 100.0);
        }
    }
}

public int SortByRating(int index1, int index2, Handle array, Handle hndl) {
    ArrayList list = view_as<ArrayList>(array);
    MatchEntry a, b;
    list.GetArray(index1, a);
    list.GetArray(index2, b);

    if (a.rating > b.rating) return -1;
    if (a.rating < b.rating) return 1;
    return 0;
}
