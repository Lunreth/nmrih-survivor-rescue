#include <sourcemod>
#include <sdktools>
#include <sdkhooks>
#include <multicolors>
#include <nmr_instructor>
#include <clientprefs>

#define PLUGIN_AUTHOR "Ulreth*"
#define PLUGIN_VERSION "1.0.8" // 24-07-2022
#define PLUGIN_NAME "[NMRiH] Survivor Rescue"

// CHANGELOG 1.0.8
/*
- Added eligible survivor choice (will pick among all clients that want to be VIP)
- Added color for some translations
- Added client volunteer cookie to get picked as VIP in future games
- New client command (!survivor) (!lider) (!carry) (!leader) with timed menu at round start
- Removed annoying spam sound
- Fixed some wrong code names
*/

#pragma semicolon 1
#pragma newdecls required

#define MAX_INSTA_EXTRACT_RANGE 512.0
#define MAX_CHOICE_TIME 11.0
#define NMRIH_MAX_PLAYERS 10

ConVar cvar_sr_enabled;
ConVar cvar_sr_debug;
ConVar cvar_sr_health;
ConVar cvar_sr_ff;
ConVar cvar_sr_event;
ConVar cvar_sr_glowmode;
ConVar cvar_sr_trail;

Handle g_hTimer_Color = INVALID_HANDLE;
Handle g_hTimer_Trail = INVALID_HANDLE;

bool g_bValid_Map = false;
bool g_bSurvivor_Extracted = false;

char g_SurvivorName[64];

float g_fPlayer_Location[NMRIH_MAX_PLAYERS][3];
float g_fSurvivor_Location[3];

int survivor = -1; // Client index
int sprite = INVALID_ENT_REFERENCE; // Entity reference

int g_Players[NMRIH_MAX_PLAYERS] = {-1,-1,-1,-1,-1,-1,-1,-1,-1,-1};
int g_PlayerCount = 0;

int g_Volunteers[NMRIH_MAX_PLAYERS] = {-1,-1,-1,-1,-1,-1,-1,-1,-1,-1};
int g_VolunteerCount = 0;

// Cookies
Handle g_hVolunteer_Cookie;
int g_ClientPreference[NMRIH_MAX_PLAYERS];

// Spam hint
int g_MsgCount[NMRIH_MAX_PLAYERS];

public Plugin myinfo =
{
	name = PLUGIN_NAME,
	author = PLUGIN_AUTHOR,
	description = "This plugin will pick a random player every round start in objective game mode, all players must cooperate to keep survivor alive until extraction, otherwise they will lose.",
	version = PLUGIN_VERSION,
	url = "http://steamcommunity.com/groups/lunreth-laboratory"
};

public void OnPluginStart()
{
	LoadTranslations("nmrih_survivor_rescue.phrases");
	
	CreateConVar("sm_survivor_rescue_version", PLUGIN_VERSION, PLUGIN_NAME, FCVAR_NONE);
	cvar_sr_enabled = CreateConVar("sm_survivor_rescue_enable", "1.0", "Enable or disable Survivor Rescue plugin.", FCVAR_NONE, true, 0.0, true, 1.0);
	cvar_sr_debug = CreateConVar("sm_survivor_rescue_debug", "0.0", "Debug mode for plugin - Will spam messages in console if set to 1", FCVAR_NONE, true, 0.0, true, 1.0);
	cvar_sr_health = CreateConVar("sm_sr_starting_health", "150.0", "Sets the starting health of a random survivor.", FCVAR_NONE, true, 1.0, true, 10000.0);
	cvar_sr_ff = CreateConVar("sm_survivor_rescue_ff", "0.0", "0 = Override FF parameters and will not receive any damage from players (not even infected)", FCVAR_NONE, true, 0.0, true, 1.0);
	cvar_sr_event = CreateConVar("sm_survivor_rescue_event", "0.0", "Use 1.0 to block team suicide after survivor death", FCVAR_NONE, true, 0.0, true, 1.0);
	cvar_sr_glowmode = CreateConVar("sm_survivor_rescue_glowmode", "0.0", "Using 1.0 will keep the old env_sprite method to show special survivor", FCVAR_NONE, true, 0.0, true, 1.0);
	cvar_sr_trail = CreateConVar("sm_survivor_rescue_trail", "0.0", "Using 1.0 will enable survivor weapon trail", FCVAR_NONE, true, 0.0, true, 1.0);
	AutoExecConfig(true, "nmrih_survivor_rescue");
	
	HookEvent("nmrih_practice_ending", Event_PracticeStart);
	HookEvent("nmrih_reset_map", Event_ResetMap);
	HookEvent("nmrih_round_begin", Event_RoundBegin);
	HookEvent("player_death", Event_PlayerDeath, EventHookMode_Pre);
	HookEvent("player_leave", Event_PlayerLeave, EventHookMode_Pre);
	
	// VOLUNTEER COMMANDS
	RegConsoleCmd("sm_survivor", Command_Survivor, "Say !survivor to be the VIP in this round");
	RegConsoleCmd("sm_leader", Command_Survivor, "Say !leader to be the VIP in this round");
	RegConsoleCmd("sm_carry", Command_Survivor, "Say !carry to be the VIP in this round");
	RegConsoleCmd("sm_lider", Command_Survivor, "Say !lider to be the VIP in this round");
	
	// VOLUNTEER COOKIE
	g_hVolunteer_Cookie = RegClientCookie("sr_volunteer_cookie", "Always get picked as the special survivor VIP", CookieAccess_Private);
	SetCookiePrefabMenu(g_hVolunteer_Cookie, CookieMenu_YesNo_Int, "Survivor Rescue Volunteer", Volunteer_Cookie_Handler);
	
	for (int i = 1; i <= MaxClients; i++)
	{
		if (!AreClientCookiesCached(i))
		{
			continue;
		}
		OnClientCookiesCached(i);
    }
	
	// + OnMapStart()
	// + OnTouch()
	// + OnClientDisconnect()
	// + OnClientPostAdminCheck()
	// + OnClientPutInServer()
	// + OnMapEnd()
}

public void OnMapStart()
{
	char map_name[65];
	GetCurrentMap(map_name, sizeof(map_name));
	if ((StrContains(map_name, "nmo_", false) != -1) || (StrContains(map_name, "nms_", false) != -1))
	{
		g_bValid_Map = true;
		PrintToServer("[SR] Valid map detected - Survivor Rescue enabled");
		LogMessage("[SR] Valid map detected - Survivor Rescue enabled");
	}
	
	if (PluginActive() == true)
	{
		for (int i = 1; i <= MaxClients; i++)
		{
			if (IsClientInGame(i))
			{
				SDKHook(i, SDKHook_OnTakeDamage, OnTakeDamage);
				g_ClientPreference[i] = 0;
			}
		}
		g_hTimer_Color = CreateTimer(5.0, Timer_SurvivorColor, _, TIMER_REPEAT);
		g_hTimer_Trail = CreateTimer(0.1, Timer_SurvivorTrail, _, TIMER_REPEAT);
	}
}

public void OnEntityCreated(int entity, const char[] classname)
{
	if ((StrEqual(classname, "func_nmrih_extractionzone")) && (PluginActive() == true))
    {
		SDKHookEx(entity, SDKHook_StartTouch, OnTouch);
	}
}

public Action Menu_Volunteer(int client, int args)
{
	Menu hMenu = new Menu(Callback_Menu_Volunteer, MENU_ACTIONS_ALL);
	char display[128];
	
	Format(display, sizeof(display), "%T", "menu_choice_volunteer", client);
	hMenu.SetTitle(display);
	
	//Format(display, sizeof(display), "My Honor Stats");
	Format(display, sizeof(display), "%T", "voting_yes", client);
	hMenu.AddItem("voting_yes", display, ITEMDRAW_DEFAULT);
	
	//Format(display, sizeof(display), "Online Players");
	Format(display, sizeof(display), "%T", "voting_no", client);
	hMenu.AddItem("voting_no", display, ITEMDRAW_DEFAULT);
	
	hMenu.AddItem("space", "",ITEMDRAW_SPACER);
	hMenu.Display(client, RoundToFloor(MAX_CHOICE_TIME));
	return Plugin_Handled;
}

public int Callback_Menu_Volunteer(Menu hMenu, MenuAction action, int param1, int param2)
{
	switch (action)
	{
		case MenuAction_DrawItem:
		{
			char info[32];
			int style;
			hMenu.GetItem(param2, info, sizeof(info), style);
			return style;
		}
		case MenuAction_Select:
		{
			char info[32];
			hMenu.GetItem(param2, info, sizeof(info));
			if (!IsPlayerInList(param1, g_Volunteers))
			{
				if (StrEqual(info, "voting_yes")) Command_Survivor(param1, 0);
				else if (StrEqual(info, "voting_no")) CPrintToChat(param1, "{blue}[Survivor Rescue]{default} %t", "choice_denied");
			}
			else
			{
				if (StrEqual(info, "voting_yes")) CPrintToChat(param1, "{blue}[Survivor Rescue]{default} %t", "command_choice_confirmed");
				else if (StrEqual(info, "voting_no")) Command_Survivor(param1, 0);
			}
		}
		case MenuAction_Cancel:
		{
			if (IsClientInGame(param1)) CPrintToChat(param1, "{blue}[Survivor Rescue]{default} %t", "choice_denied");
		}
		case MenuAction_End:
		{
			delete hMenu;
		}
	}
 	return 0;
}

public Action Command_Survivor(int client, int args)
{
	if (PluginActive() == true)
	{
		if (!IsPlayerAlive(client))
		{
			CPrintToChat(client, "{blue}[Survivor Rescue]{default} %t", "command_invalid_dead");
			return Plugin_Continue;
		}
		if (survivor > 0)
		{
			CPrintToChat(client, "{blue}[Survivor Rescue]{default} %t", "command_invalid_after_pick");
			return Plugin_Continue;
		}
		if (!IsPlayerInList(client, g_Volunteers))
		{
			if (AddToPlayerArray(client, g_Volunteers)) g_VolunteerCount++;
			CPrintToChat(client, "{blue}[Survivor Rescue]{default} %t", "command_choice_confirmed");
		}
		else
		{
			if (DeletePlayer(client, g_Volunteers)) g_VolunteerCount--;
			CPrintToChat(client, "{blue}[Survivor Rescue]{default} %t", "command_choice_deny");
		}
	}
	return Plugin_Continue;
}

public Action Event_PracticeStart(Event event, const char[] name, bool dontBroadcast)
{
	if (PluginActive() == true)
	{
		VariablesToZero();
		if (GetConVarFloat(cvar_sr_debug) == 1.0)
		{
			PrintToServer("[Survivor Rescue] Variables set to zero.");
			LogMessage("[Survivor Rescue] Variables set to zero.");
		}
	}
	return Plugin_Continue;
}

public Action Event_ResetMap(Event event, const char[] name, bool dontBroadcast)
{
	if (PluginActive() == true)
	{
		VariablesToZero();
		CPrintToChatAll("[Survivor Rescue] %t", "survivor_loading_choice");
		CreateTimer(0.5, Timer_CheckPlayers);
	}
	return Plugin_Continue;
}
public Action Timer_CheckPlayers(Handle timer)
{
	for (int i = 1; i <= MaxClients; i++)
	{
		if (IsClientInGame(i))
		{
			if (IsPlayerAlive(i))
			{
				// ALWAYS ADD PLAYER TO GLOBAL ARRAY
				if (AddToPlayerArray(i, g_Players)) g_PlayerCount++;
				
				if (g_ClientPreference[i] > 0)
				{
					// CLIENT WANTS TO BECOME VIP EVERY Round
					if (!IsPlayerInList(i, g_Volunteers)) Command_Survivor(i, 0);
					else CPrintToChat(i, "{blue}[Survivor Rescue]{default} %t", "command_choice_confirmed");
				}
				else
				{
					// CLIENT HAS COOKIE DEFAULT VALUE 0
					if (!IsPlayerInList(i, g_Volunteers)) Menu_Volunteer(i, 0);
					else CPrintToChat(i, "{blue}[Survivor Rescue]{default} %t", "command_choice_confirmed");
				}
			}
		}
	}
	CreateTimer(MAX_CHOICE_TIME, Timer_PickSurvivor);
	return Plugin_Continue;
}

public Action Timer_PickSurvivor(Handle timer)
{
	// PICKS RANDOM SURVIVOR FROM PLAYERS
	survivor = RandomPlayer();
	if (survivor > 0)
	{
		SetSurvivorGlow();
		SetClientHealth(survivor, GetConVarFloat(cvar_sr_health));
		GetClientName(survivor, g_SurvivorName, sizeof(g_SurvivorName));
		CPrintToChatAll("[Survivor Rescue] %t", "survivor_picked", g_SurvivorName);
		PrintCenterTextAll("%t", "survivor_picked", g_SurvivorName);
		if (GetConVarFloat(cvar_sr_debug) == 1.0)
		{
			PrintToServer("[Survivor Rescue] %s is the special survivor! Cooperate together and keep him alive at any cost.", g_SurvivorName);
			LogMessage("[Survivor Rescue] %s is the special survivor! Cooperate together and keep him alive at any cost.", g_SurvivorName);
		}
		CPrintToChat(survivor, "{blue}[Survivor Rescue]{default} %T", "survivor_private_message", survivor);
	}
	return Plugin_Continue;
}

public Action Event_RoundBegin(Event event, const char[] name, bool dontBroadcast)
{
	if (PluginActive() == true)
	{
		if (survivor > 0) PrintCenterText(survivor, "%T", "survivor_center_message", survivor);
	}
	return Plugin_Continue;
}

public Action Event_PlayerDeath(Event event, const char[] name, bool dontBroadcast)
{
	if (PluginActive() == true)
	{
		int userid = event.GetInt("userid");
		int client = GetClientOfUserId(userid);
		if (DeletePlayer(client, g_Players)) g_PlayerCount--;
		// MISSION FAILED WHEN SURVIVOR DIES
		if ((survivor != -1) && (client == survivor) && (g_bSurvivor_Extracted == false))
		{
			GetClientName(survivor, g_SurvivorName, sizeof(g_SurvivorName));
			CPrintToChatAll("{blue}[Survivor Rescue]{default} %t", "survivor_death", g_SurvivorName);
			PrintCenterTextAll("%t", "survivor_death", g_SurvivorName);
			if (GetConVarFloat(cvar_sr_debug) == 1.0)
			{
				PrintToServer("[Survivor Rescue] %s is dead! Mission failed!", g_SurvivorName);
				LogMessage("[Survivor Rescue] %s is dead! Mission failed!", g_SurvivorName);
			}
			RemoveSurvivor();
			if (GetConVarFloat(cvar_sr_event) == 0.0)
			{
				FreezePlayers();
				CreateTimer(6.0, Timer_KillPlayers);
			}
		}
	}
	return Plugin_Continue;
}

public Action OnTouch(int entity, int client)
{
	if (PluginActive() == true)
	{
		char client_classname[64];
		GetEdictClassname(client, client_classname, 64);
		if (StrEqual(client_classname, "player", true))
		{
			// MISSION COMPLETE
			if (g_bSurvivor_Extracted == true)
			{
				if (DeletePlayer(client, g_Players)) g_PlayerCount--;
			}
			else if ((survivor != -1) && (client == survivor) && (g_bSurvivor_Extracted == false))
			{
				g_bSurvivor_Extracted = true;
				GetClientName(survivor, g_SurvivorName, sizeof(g_SurvivorName));
				if (GetConVarFloat(cvar_sr_event) == 1.0)
				{
					CPrintToChatAll("{blue}[Survivor Rescue]{default} VIP %s extracted!", g_SurvivorName);
					PrintCenterTextAll("VIP %s extracted!", g_SurvivorName);
					PrintCenterText(survivor, "VIP %s extracted!", g_SurvivorName);
				}
				else
				{
					CPrintToChatAll("{blue}[Survivor Rescue]{default} %t", "survivor_extracted", g_SurvivorName);
					PrintCenterTextAll("%t", "survivor_extracted", g_SurvivorName);
					PrintCenterText(survivor, "%T", "survivor_hub_complete", survivor);
				}
				if (GetConVarFloat(cvar_sr_debug) == 1.0)
				{
					PrintToServer("[Survivor Rescue] %s successfully extracted!", g_SurvivorName);
					LogMessage("[Survivor Rescue] %s successfully extracted!", g_SurvivorName);
				}
				RemoveSurvivor();
				SetInput_Entity("func_nmrih_extractionzone", "Disable");
				CreateTimer(0.1, Timer_ExtractFix, _, TIMER_FLAG_NO_MAPCHANGE);
			}
			else if ((survivor != -1) && (client != survivor) && (g_bSurvivor_Extracted == false) && (GetConVarFloat(cvar_sr_event) == 0.0))
			{
				// BLOCKS EXTRACTION IF PLAYER IS NOT SURVIVOR
				if (client > 0)
				{
					//GetClientAbsOrigin(survivor, g_fSurvivor_Location);
					GetEntityAbsOrigin(survivor, g_fSurvivor_Location);
					TeleportEntity(client, g_fSurvivor_Location, NULL_VECTOR, NULL_VECTOR);
					PrintHintText(client, "[Survivor Rescue] %T", "not_survivor", client, g_SurvivorName);
					PrintCenterText(client, "%T", "not_survivor", client, g_SurvivorName);
					return Plugin_Handled;
				}
			}
		}
	}
	return Plugin_Continue;
}

public Action Timer_ExtractFix(Handle timer)
{
	SetInput_Entity("func_nmrih_extractionzone", "Enable");
	
	// INSTA EXTRACT FOR NEARBY PLAYERS
	for (int i = 1; i <= MaxClients; i++)
	{
		if ((IsClientInGame(i)) && (survivor != i))
		{
			if (GetVectorDistance(g_fSurvivor_Location, g_fPlayer_Location[i]) <= MAX_INSTA_EXTRACT_RANGE)
			{
				ServerCommand("extractplayer %d", GetClientUserId(i));
				if (DeletePlayer(i, g_Players)) g_PlayerCount--;
			}
		}
	}
	return Plugin_Stop;
}

public Action OnTakeDamage(int victim, int &attacker, int &inflictor, float &damage, int &damagetype)
{
	if ((0 < victim) && (victim <= MaxClients) && (0 < attacker) && (attacker <= MaxClients) && (victim != attacker))
	{
		if ((victim == survivor) && (g_bSurvivor_Extracted == false) && (GetConVarFloat(cvar_sr_ff) == 0.0))
		{
			damage = 0.0;
			//PrintHintText(attacker,"[SR] Friendly fire disabled for special survivor.");
			PrintHintText(attacker,"[SR] %T", "survivor_ff", attacker);
			return Plugin_Changed;
		}
	}
	return Plugin_Continue;
}

public void OnClientPutInServer(int client)
{
	if (PluginActive() == true)
	{
		g_MsgCount[client] = 0;
		SDKHook(client, SDKHook_OnTakeDamage, OnTakeDamage);
		
		if (survivor > 0)
		{
			if (IsClientInGame(survivor))
			{
				if (IsPlayerAlive(survivor))
				{
					ShowSurvivorHint(client, "%t", "survivor_all_hud", g_SurvivorName);
				}
			}
		}
	}
}

public void OnClientCookiesCached(int client)
{
	char sValue[8];
	GetClientCookie(client, g_hVolunteer_Cookie, sValue, sizeof(sValue));
    
	g_ClientPreference[client] = (sValue[0] != '\0' && StringToInt(sValue));
}

public void Volunteer_Cookie_Handler(int client, CookieMenuAction action, any info, char[] buffer, int maxlen)
{
	switch (action)
	{
		case CookieMenuAction_DisplayOption:
		{
		}
		case CookieMenuAction_SelectOption:
		{
			OnClientCookiesCached(client);
		}
	}
}

public Action Event_PlayerLeave(Event event, const char[] name, bool dontBroadcast)
{
	if (PluginActive() == true)
	{
		int client = GetEventInt(event, "index");
		SDKUnhook(client, SDKHook_OnTakeDamage, OnTakeDamage);
		if (DeletePlayer(client, g_Players)) g_PlayerCount--;
		if (DeletePlayer(client, g_Volunteers)) g_VolunteerCount--;
		// MISSION MUST RESTART
		if ((survivor != -1) && (client == survivor) && (g_bSurvivor_Extracted == false))
		{
			GetClientName(survivor, g_SurvivorName, sizeof(g_SurvivorName));
			//PrintToChatAll("[Survivor Rescue] %s was the special survivor and left the game! Round must restart to pick new hero.", g_SurvivorName);
			CPrintToChatAll("{blue}[Survivor Rescue]{default} %t", "survivor_left", g_SurvivorName);
			//PrintCenterTextAll("Round must restart to pick new survivor!", g_SurvivorName);
			PrintCenterTextAll("%t", "survivor_restart", g_SurvivorName);
			if (GetConVarFloat(cvar_sr_debug) == 1.0)
			{
				PrintToServer("[Survivor Rescue] %s was the special survivor and left the game! Round must restart to pick new hero.", g_SurvivorName);
				LogMessage("[Survivor Rescue] %s was the special survivor and left the game! Round must restart to pick new hero.", g_SurvivorName);
			}
			RemoveSurvivor();
			if (GetConVarFloat(cvar_sr_event) == 0.0)
			{
				FreezePlayers();
				CreateTimer(5.0, Timer_EndRound);
			}
		}
	}
	return Plugin_Continue;
}

public void OnMapEnd()
{
	// DELETE TIMER JUST IN CASE
	delete g_hTimer_Color;
	delete g_hTimer_Trail;
}

void VariablesToZero()
{
	g_bSurvivor_Extracted = false;
	survivor = -1;
	sprite = INVALID_ENT_REFERENCE;
	g_PlayerCount = 0;
	g_VolunteerCount = 0;
	for (int i = 0; i <= MaxClients; i++)
	{
		g_Players[i] = -1;
		g_Volunteers[i] = -1;
		g_MsgCount[i] = 0;
	}
}

bool PluginActive()
{
	// CHECKS IF PLUGIN HAS ACTIVE CVAR
	bool answer = false;
	if ((g_bValid_Map == true) && (GetConVarFloat(cvar_sr_enabled) == 1.0))
	{
		answer = true;
	}
	return answer;
}

bool AddToPlayerArray(int client, int[] array)
{
	// LOOKS FOR FREE SPACE INSIDE PLAYERS ARRAY
	for (int i = 0; i <= MaxClients; i++)
	{
		if (array[i] == -1)
		{
			array[i] = client;
			return true;
		}
	}
	return false;
}

bool DeletePlayer(int client, int[] array)
{
	// FINDS PLAYER INSIDE ARRAY
	for (int i = 0; i <= MaxClients; i++)
	{
		if (array[i] == client)
		{
			array[i] = -1;
			return true;
		}
	}
	return false;
}

bool IsPlayerInList(int client, int[] array)
{
	for (int i = 0; i <= MaxClients; i++)
	{
		if (array[i] == client)
		{
			return true;
		}
	}
	return false;
}

int RandomPlayer()
{
	// PICKS RANDOM PLAYER FROM ARRAY
	int random_client = -1;
	
	if (g_VolunteerCount > 0)
	{
		random_client = g_Volunteers[GetRandomInt(0, g_VolunteerCount-1)];
	}
	else
	{
		random_client = g_Players[GetRandomInt(0, g_PlayerCount-1)];
	}
	return random_client;
}

void SetSurvivorGlow()
{
	if (GetConVarFloat(cvar_sr_glowmode) == 0.0)
	{
		// Renaming picked survivor
		//char new_targetname[64] = "sr_player_name";
		//DispatchKeyValue(survivor, "targetname", "sr_player_name");
		//SetEntPropString(survivor, Prop_Data, "m_iName", "sr_player_name");
		//SetVariantString("targetname sr_player_name");
		//AcceptEntityInput(survivor, "AddOutput");
		
		// METHOD 1 - env_instructor_hint
		for (int i = 1; i <= MaxClients; i++)
		{
			if (IsClientInGame(i))
			{
				if (survivor == i) ShowSurvivorHint(survivor, "%t", "survivor_indicator");
				else ShowSurvivorHint(i, "%t", "survivor_all_hud", g_SurvivorName);
			}
		}
		// METHOD 2 - GLOW COLOR
		DispatchKeyValue(survivor, "glowable", "1"); 
		DispatchKeyValue(survivor, "glowblip", "1");
		DispatchKeyValue(survivor, "glowcolor", "80 200 255");
		DispatchKeyValue(survivor, "glowdistance", "9999");
		AcceptEntityInput(survivor, "enableglow");
	}
	else
	{
		// ENV SPRITE GLOW METHOD + TRAIL
		SetEntityRenderMode(survivor, RENDER_GLOW);
		SetEntityRenderColor(survivor, 92, 92, 232, 232);
		
		int iSprite = CreateEntityByName("env_sprite");
		DispatchKeyValue(iSprite, "classname", "env_sprite");
		DispatchKeyValue(iSprite, "spawnflags", "1");
		DispatchKeyValue(iSprite, "scale", "0.2");
		DispatchKeyValue(iSprite, "rendermode", "1");
		DispatchKeyValue(iSprite, "rendercolor", "255 255 255");
		DispatchKeyValue(iSprite, "model", "materials/sprites/blueglow2.vmt");
		DispatchSpawn(iSprite);
		
		float origin[3];

		if(IsValidEntity(iSprite))
		{
			//if (survivor > 0) GetClientAbsOrigin(survivor, origin);
			if (survivor > 0) GetEntityAbsOrigin(survivor, origin);
			origin[2] = origin[2] + 16.0;
			TeleportEntity(iSprite, origin, NULL_VECTOR, NULL_VECTOR);
			SetVariantString("!activator");
			AcceptEntityInput(iSprite, "SetParent", survivor);
			//SetVariantString("pelvis");
			//AcceptEntityInput(iSprite, "SetParentAttachment", survivor, survivor, 0);
		}
		sprite = EntIndexToEntRef(iSprite);
	}
}

void ShowSurvivorHint(int client, const char[] format, any...)
{
	SetGlobalTransTarget(client);
	
	char buffer[512];
	VFormat(buffer, sizeof(buffer), format, 3);
	
	SendInstructorHint(client, "survivor_rescue_hint", "survivor_rescue_hint", survivor, 0, 0, ICON_CAUTION, ICON_CAUTION, buffer, buffer, 64, 64, 255, 16.0, 2048.0, 0, "", false, true, false, false, "", 0);
}

void SetClientHealth(int client, float value)
{
	//SetEntProp(client, Prop_Data, "m_iMaxHealth", value);
	SetEntityHealth(client, RoundToNearest(value));
	if (GetConVarFloat(cvar_sr_debug) == 1.0)
	{
		PrintToServer("[SR] Survivor starts with %f health points.", value);
		LogMessage("[SR] Survivor starts with %f health points.", value);
	}
	//SetEntProp(client, Prop_Data, "m_iMaxHealth", value);
}

void FreezePlayers()
{
	for (int i = 1; i <= MaxClients; i++)
	{
		if (IsClientInGame(i))
		{
			if (IsPlayerAlive(i))
			{
				SetEntPropFloat(i, Prop_Data, "m_flLaggedMovementValue", 0.0);
				SetEntityMoveType(i, MOVETYPE_NONE);
			}
		}
	}
}

int GetGameStateEntity()
{
	int nmrih_game_state = -1;
	while((nmrih_game_state = FindEntityByClassname(nmrih_game_state, "nmrih_game_state")) != -1)
		return nmrih_game_state;
	nmrih_game_state = CreateEntityByName("nmrih_game_state");
	if(IsValidEntity(nmrih_game_state) && DispatchSpawn(nmrih_game_state))
		return nmrih_game_state;
	return -1;
}

void SetInput_Entity(char[] classname, char[] input)
{
	int i = -1;
	while ((i = FindEntityByClassname(i, classname)) != -1)
	{
		AcceptEntityInput(i, input);
	}
}

bool NukePlayers()
{
	int state = GetGameStateEntity();
	if(IsValidEntity(state))
		return AcceptEntityInput(state, "NukePlayers");
	return false;
}

bool EndRound()
{
	int state = GetGameStateEntity();
	if(IsValidEntity(state))
		return AcceptEntityInput(state, "RestartRound");
	return false;
}

void RemoveSurvivor()
{
	if (IsClientInGame(survivor)) SetEntityRenderColor(survivor, 255, 255, 255, 255);
	int sprite_index = EntRefToEntIndex(sprite);
	if(IsValidEntity(sprite_index))
	{
		AcceptEntityInput(sprite_index, "HideSprite");
		AcceptEntityInput(sprite_index, "Kill");
	}
	// Remove new env_instructor_hint
	for (int i = 1; i <= MaxClients; i++)
	{
		if (IsClientInGame(i)) RemoveInstructorHint(i, "survivor_rescue_hint");
	}
	survivor = -1;
}

void KillPlayers()
{
	NukePlayers();
	for (int i = 1; i <= MaxClients; i++)
	{
		if (IsClientInGame(i))
		{
			if (IsPlayerAlive(i)) ForcePlayerSuicide(i);
		}
	}
}

public Action Timer_KillPlayers(Handle timer)
{
	KillPlayers();
	VariablesToZero();
	return Plugin_Continue;
}

public Action Timer_EndRound(Handle timer)
{
	EndRound();
	VariablesToZero();
	return Plugin_Continue;
}

public Action Timer_SurvivorColor(Handle timer)
{
	if ((g_hTimer_Color != timer) || (g_hTimer_Color == null)) return Plugin_Stop;
	if ((g_bSurvivor_Extracted == true) || (survivor == -1)) return Plugin_Continue;
	// RE-APPLY COLOR IN CASE PLAYER CHANGE MODEL
	if (IsClientInGame(survivor))
	{
		if (IsPlayerAlive(survivor))
		{
			if (GetConVarFloat(cvar_sr_glowmode) == 1.0)
			{
				SetEntityRenderMode(survivor, RENDER_GLOW);
				SetEntityRenderColor(survivor, 92, 92, 232, 232);
			}
			for (int i = 1; i <= MaxClients; i++)
			{
				if (IsClientInGame(i))
				{
					if (i != survivor)
					{
						if (g_MsgCount[i] < 3)
						{
							ShowSurvivorHint(i, "%t", "survivor_all_hud", g_SurvivorName);
							g_MsgCount[i]++;
						}
						DispatchKeyValue(i, "glowable", "0"); 
						DispatchKeyValue(i, "glowblip", "0");
						AcceptEntityInput(i, "disableglow");
						PrintHintText(i, "[Survivor Rescue] %T", "survivor_all_hud", i, g_SurvivorName);
					}
					else
					{
						if (g_MsgCount[i] < 3)
						{
							ShowSurvivorHint(survivor, "%t", "survivor_indicator");
							g_MsgCount[i]++;
						}
						if (GetConVarFloat(cvar_sr_glowmode) == 0.0)
						{
							DispatchKeyValue(i, "glowable", "1"); 
							DispatchKeyValue(i, "glowblip", "1");
							AcceptEntityInput(i, "enableglow");
						}
						PrintHintText(i, "[Survivor Rescue] %T", "survivor_indicator", i);
					}
				}
			}
		}
	}
	return Plugin_Continue;
}

public Action Timer_SurvivorTrail(Handle timer)
{
	if ((g_hTimer_Trail != timer) || (g_hTimer_Trail == null)) return Plugin_Stop;
	// CHECKING SURVIVOR EXTRACT STATUS
	if ((g_bSurvivor_Extracted == true) || (survivor == -1)) return Plugin_Continue;
	// GET PLAYER LOCATIONS
	for (int i = 1; i <= MaxClients; i++)
	{
		if (IsClientInGame(i))
		{
			if (IsPlayerAlive(i))
			{
				if (survivor == i) GetEntityAbsOrigin(i, g_fSurvivor_Location);
				else GetEntityAbsOrigin(i, g_fPlayer_Location[i]);
			}
		}
	}
	// RETURN AFTER THAT WHEN MODE IS 0
	if (GetConVarFloat(cvar_sr_trail) == 0.0) return Plugin_Continue;
	
	// RE-APPLY OLD TRAIL TO SURVIVOR
	if (IsClientInGame(survivor))
	{
		if (IsPlayerAlive(survivor))
		{
			int color[4] = {80, 200, 255, 128};
			TE_SetupBeamFollow(survivor, PrecacheGeneric("materials/sprites/laserbeam.vmt", true), 0, 0.5, 0.5, 0.5, 1, color);
			TE_SendToAll();
		}
	}
	return Plugin_Continue;
}

void GetEntityAbsOrigin(int entity, float origin[3])
{
	char class[32];
	int offs;
	
	GetEntPropVector(entity, Prop_Send, "m_vecOrigin", origin);
	
	if (!GetEntityNetClass(entity, class, sizeof(class)) || (offs = FindSendPropInfo(class, "m_vecMins")) == -1)
	{
		return;
	}
	
	float mins[3];
	float maxs[3];
	
	GetEntDataVector(entity, offs, mins);
	GetEntPropVector(entity, Prop_Send, "m_vecMaxs", maxs);
	
	origin[0] += (mins[0] + maxs[0]) * 0.5;
	origin[1] += (mins[1] + maxs[1]) * 0.5;
	origin[2] += (mins[2] + maxs[2]) * 0.5;
}