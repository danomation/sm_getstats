#include <sourcemod>
#include <ripext>

public Plugin myinfo = {
    name = "sm_getstats",
    author = "alpha",
    description = "Gets cartesianbear's custom stats via HTTPS and returns json",
    version = "1.0",
    url = ""
};

public void OnPluginStart() {
    RegConsoleCmd("sm_getstats", Command_GetStats);
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

public void OnStatsReceived(HTTPResponse response, any userid) {
    int client = GetClientOfUserId(userid);
    if (client <= 0) return;

    PrintToServer("HTTP Status: %d", response.Status);

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
                PrintToChat(client, "Rating:%.2f GRank:#%d", rating * 100.0 , grank) ;
                PrintToChat(client, "VORP:%.2f %%", (vorp - 1.0) * 100.0) ;

                delete general;
            } else {
                PrintToChat(client, "No general stats found");
            }

            //JSONArray implants = view_as<JSONArray>(json.Get("implants"));
            //if (implants != null) {
            //    int implantCount = implants.Length;
            //    PrintToChat(client, "Implants: %d total", implantCount);

            //    for (int i = 0; i < implantCount && i < 3; i++) {
            //        JSONObject implant = view_as<JSONObject>(implants.Get(i));
            //        if (implant != null) {
            //            int iid = implant.GetInt("iid");
            //            float energy = implant.GetFloat("energy");
            //            PrintToChat(client, "Implant %d: ID:%d Energy:%.0f", i+1, iid, energy);
            //            delete implant;
            //        }
            //    }

            //    delete implants;
            //}

            delete json;
        } else {
            PrintToChat(client, "Failed to parse JSON response");
        }
    } else {
        PrintToChat(client, "HTTP Error: %d", response.Status);

        if (response.Data != null) {
            char errorData[256];
            response.Data.ToString(errorData, sizeof(errorData));
            PrintToServer("Error response: %s", errorData);
        }
    }
}
