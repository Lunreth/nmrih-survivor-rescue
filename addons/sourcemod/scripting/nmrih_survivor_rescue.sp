#include <sourcemod>
#include <sdktools>
#include <sdkhooks>
#include <autoexecconfig>

#define PLUGIN_AUTHOR "Ulreth*"
#define PLUGIN_VERSION "1.0.4" // 5-07-2021
#define PLUGIN_NAME "[NMRiH] Survivor Rescue"

// CHANGELOG 1.0.4
/*
- Added CVAR to enable or disable survivor weapon trail
- Fixed multiple glow exploit
*/

#pragma semicolon 1
#pragma newdecls required

ConVar cvar_sr_enabled;
ConVar cvar_sr_debug;
ConVar cvar_survivor_health;
ConVar cvar_sr_ff;
ConVar cvar_sr_event;
ConVar cvar_sr_glowmode;
ConVar cvar_sr_trail;

Handle timer_s_color = INVALID_HANDLE;
Handle timer_s_trail = INVALID_HANDLE;

bool objective_map = false;
bool survivor_extracted = false;

char survivor_name[64];

float survivor_location[3];

int survivor = -1;
int players_count = 0;
int sprite = -1; // Entity reference
int players_array[9] = {-1,-1,-1,-1,-1,-1,-1,-1,-1};

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
	char map[65];
	GetCurrentMap(map, sizeof(map));
	if (StrContains(map, "nmo_", false) >= 0)
	{
		objective_map = true;
		PrintToServer("[SR] Objective map detected - Survivor Rescue enabled");
		LogMessage("[SR] Objective map detected - Survivor Rescue enabled");
	}
	
	AutoExecConfig_SetFile("nmrih_survivor_rescue");
	AutoExecConfig_SetCreateFile(true);
	AutoExecConfig_CreateConVar("sm_survivor_rescue_version", PLUGIN_VERSION, PLUGIN_NAME, FCVAR_NONE);
	cvar_sr_enabled = AutoExecConfig_CreateConVar("sm_survivor_rescue_enable", "1.0", "Enable or disable Survivor Rescue plugin.", FCVAR_NONE, true, 0.0, true, 1.0);
	cvar_sr_debug = AutoExecConfig_CreateConVar("sm_survivor_rescue_debug", "0.0", "Debug mode for plugin - Will spam messages in console if set to 1", FCVAR_NONE, true, 0.0, true, 1.0);
	cvar_survivor_health = AutoExecConfig_CreateConVar("sm_sr_starting_health", "100.0", "Sets the starting health of a random survivor.", FCVAR_NONE, true, 1.0, true, 10000.0);
	cvar_sr_ff = AutoExecConfig_CreateConVar("sm_survivor_rescue_ff", "1.0", "1 = Default (will receive damage when infected or when CVARs dictate) | 0 = Override FF parameters and will not receive any damage from players (not even infected)", FCVAR_NONE, true, 0.0, true, 1.0);
	cvar_sr_event = AutoExecConfig_CreateConVar("sm_survivor_rescue_event", "0.0", "Use 1.0 to block team suicide after survivor death", FCVAR_NONE, true, 0.0, true, 1.0);
	cvar_sr_glowmode = AutoExecConfig_CreateConVar("sm_survivor_rescue_glowmode", "0.0", "Using 1.0 will keep the old env_sprite method to show special survivor", FCVAR_NONE, true, 0.0, true, 1.0);
	cvar_sr_trail = AutoExecConfig_CreateConVar("sm_survivor_rescue_trail", "0.0", "Using 1.0 will enable survivor weapon trail", FCVAR_NONE, true, 0.0, true, 1.0);
	AutoExecConfig_ExecuteFile();
	AutoExecConfig_CleanFile();
	
	HookEvent("nmrih_practice_ending", Event_PracticeStart);
	HookEvent("nmrih_reset_map", Event_ResetMap);
	HookEvent("nmrih_round_begin", Event_RoundBegin);
	HookEvent("player_death", Event_PlayerDeath, EventHookMode_Pre);
	HookEvent("player_leave", Event_PlayerLeave, EventHookMode_Pre);
	// PLUS OnMapStart()
	// PLUS OnTouch()
	// PLUS OnClientDisconnect()
	// PLUS OnMapEnd()
}

public void OnMapStart()
{
	if (PluginActive() == true)
	{
		for (int i = 1; i <= MaxClients; i++)
		{
			if (IsClientInGame(i)) SDKHook(i, SDKHook_OnTakeDamage, OnTakeDamage);
		}
		timer_s_color = CreateTimer(5.0, Timer_SurvivorColor, _, TIMER_REPEAT);
		timer_s_trail = CreateTimer(0.1, Timer_SurvivorTrail, _, TIMER_REPEAT);
	}
}

public void OnEntityCreated(int entity, const char[] classname)
{
	if ((StrEqual(classname, "func_nmrih_extractionzone")) && (PluginActive() == true))
    {
		SDKHookEx(entity, SDKHook_StartTouch, OnTouch);
	}
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
			if (IsPlayerAlive(i)) AddToPlayerArray(i);
		}
	}
	CreateTimer(0.5, Timer_PickSurvivor);
	return Plugin_Continue;
}

public Action Timer_PickSurvivor(Handle timer)
{
	// PICKS RANDOM SURVIVOR FROM PLAYERS
	survivor = RandomPlayer();
	if (survivor > 0)
	{
		SetSurvivorGlow();
		SetClientHealth(survivor, GetConVarFloat(cvar_survivor_health));
		GetClientName(survivor, survivor_name, sizeof(survivor_name));
		PrintToChatAll("[Survivor Rescue] %t", "survivor_picked", survivor_name);
		PrintCenterTextAll("%t", "survivor_picked", survivor_name);
		if (GetConVarFloat(cvar_sr_debug) == 1.0)
		{
			PrintToServer("[Survivor Rescue] %s is the special survivor! Cooperate together and keep him alive at any cost.", survivor_name);
			LogMessage("[Survivor Rescue] %s is the special survivor! Cooperate together and keep him alive at any cost.", survivor_name);
		}
		PrintToChat(survivor, "[Survivor Rescue] %T", "survivor_private_message", survivor);
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
		DeletePlayer(client);
		// MISSION FAILED WHEN SURVIVOR DIES
		if ((survivor != -1) && (client == survivor) && (survivor_extracted == false))
		{
			GetClientName(survivor, survivor_name, sizeof(survivor_name));
			PrintToChatAll("[Survivor Rescue] %t", "survivor_death", survivor_name);
			PrintCenterTextAll("%t", "survivor_death", survivor_name);
			if (GetConVarFloat(cvar_sr_debug) == 1.0)
			{
				PrintToServer("[Survivor Rescue] %s is dead! Mission failed!", survivor_name);
				LogMessage("[Survivor Rescue] %s is dead! Mission failed!", survivor_name);
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
			if (survivor_extracted == true) DeletePlayer(client);
			else if ((survivor != -1) && (client == survivor) && (survivor_extracted == false))
			{
				survivor_extracted = true;
				GetClientName(survivor, survivor_name, sizeof(survivor_name));
				if (GetConVarFloat(cvar_sr_event) == 1.0)
				{
					PrintToChatAll("[Survivor Rescue] VIP %s extracted!", survivor_name);
					PrintCenterTextAll("VIP %s extracted!", survivor_name);
					PrintCenterText(survivor, "VIP %s extracted!", survivor_name);
				}
				else
				{
					PrintToChatAll("[Survivor Rescue] %t", "survivor_extracted", survivor_name);
					PrintCenterTextAll("%t", "survivor_extracted", survivor_name);
					PrintCenterText(survivor, "%T", "survivor_hub_complete", survivor);
				}
				if (GetConVarFloat(cvar_sr_debug) == 1.0)
				{
					PrintToServer("[Survivor Rescue] %s successfully extracted!", survivor_name);
					LogMessage("[Survivor Rescue] %s successfully extracted!", survivor_name);
				}
				RemoveSurvivor();
				SetInput_Entity("func_nmrih_extractionzone", "Disable");
				CreateTimer(0.1, Timer_ExtractFix, _, TIMER_FLAG_NO_MAPCHANGE);
			}
			else if ((survivor != -1) && (client != survivor) && (survivor_extracted == false) && (GetConVarFloat(cvar_sr_event) == 0.0))
			{
				// BLOCKS EXTRACTION IF PLAYER IS NOT SURVIVOR
				if (client > 0)
				{
					GetClientAbsOrigin(survivor, survivor_location);
					TeleportEntity(client, survivor_location, NULL_VECTOR, NULL_VECTOR);
					PrintHintText(client, "[Survivor Rescue] %T", "not_survivor", client, survivor_name);
					PrintCenterText(client, "%T", "not_survivor", client, survivor_name);
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
	return Plugin_Stop;
}

public Action OnTakeDamage(int victim, int &attacker, int &inflictor, float &damage, int &damagetype)
{
	if ((victim > 0) && (victim <= MaxClients) && (attacker > 0) && (attacker <= MaxClients) && (victim != attacker))
	{
		if ((victim == survivor) && (survivor_extracted == false) && (GetConVarFloat(cvar_sr_ff) == 0.0))
		{
			damage = 0.0;
			//PrintHintText(attacker,"[SR] Friendly fire disabled for special survivor.");
			PrintHintText(attacker,"[SR] %T", "survivor_ff", attacker);
			return Plugin_Changed;
		}
		else
		{
			return Plugin_Continue;
		}
	}
	return Plugin_Continue;
}

public void OnClientPutInServer(int client)
{
	if (PluginActive() == true)
	{
		SDKHook(client, SDKHook_OnTakeDamage, OnTakeDamage);
	}
}

public Action Event_PlayerLeave(Event event, const char[] name, bool dontBroadcast)
{
	if (PluginActive() == true)
	{
		int client = GetEventInt(event, "index");
		SDKUnhook(client, SDKHook_OnTakeDamage, OnTakeDamage);
		DeletePlayer(client);
		// MISSION MUST RESTART
		if ((survivor != -1) && (client == survivor) && (survivor_extracted == false))
		{
			GetClientName(survivor, survivor_name, sizeof(survivor_name));
			//PrintToChatAll("[Survivor Rescue] %s was the special survivor and left the game! Round must restart to pick new hero.", survivor_name);
			PrintToChatAll("[Survivor Rescue] %t", "survivor_left", survivor_name);
			//PrintCenterTextAll("Round must restart to pick new survivor!", survivor_name);
			PrintCenterTextAll("%t", "survivor_restart", survivor_name);
			if (GetConVarFloat(cvar_sr_debug) == 1.0)
			{
				PrintToServer("[Survivor Rescue] %s was the special survivor and left the game! Round must restart to pick new hero.", survivor_name);
				LogMessage("[Survivor Rescue] %s was the special survivor and left the game! Round must restart to pick new hero.", survivor_name);
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
	delete timer_s_color;
	delete timer_s_trail;
}

void VariablesToZero()
{
	survivor_extracted = false;
	survivor = -1;
	players_count = 0;
	for (int i = 0; i < MaxClients; i++) players_array[i] = -1;
}

bool PluginActive()
{
	// CHECKS IF PLUGIN HAS ACTIVE CVAR
	bool answer = false;
	if ((objective_map == true) && (GetConVarFloat(cvar_sr_enabled) == 1.0))
	{
		answer = true;
	}
	return answer;
}

void AddToPlayerArray(int client)
{
	SetEntityRenderColor(client, 255, 255, 255, 255);
	// LOOKS FOR FREE SPACE INSIDE PLAYERS ARRAY
	for (int i = 0; i < MaxClients; i++)
	{
		if (players_array[i] == -1)
		{
			players_array[i] = client;
			players_count = (players_count + 1);
			break;
		}
	}
}

void DeletePlayer(int client)
{
	SetEntityRenderColor(client, 255, 255, 255, 255);
	for (int i = 0; i < MaxClients; i++)
	{
		if (players_array[i] == client)
		{
			players_count = (players_count - 1);
			players_array[i] = -1;
			break;
		}
	}
}

int RandomPlayer()
{
	// PICKS RANDOM PLAYER FROM ARRAY
	int random_client = -1;
	random_client = players_array[GetRandomInt(0,players_count-1)];
	return random_client;
}

void SetSurvivorGlow()
{
	if (GetConVarFloat(cvar_sr_glowmode) == 0.0)
	{
		DispatchKeyValue(survivor, "glowable", "1"); 
		DispatchKeyValue(survivor, "glowblip", "1");
		DispatchKeyValue(survivor, "glowcolor", "80 200 255");
		DispatchKeyValue(survivor, "glowdistance", "9999");
		AcceptEntityInput(survivor, "enableglow");
	}
	else
	{
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
			if (survivor > 0) GetClientAbsOrigin(survivor, origin);
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

void SetClientHealth(int client, float value)
{
	//SetEntProp(client, Prop_Data, "m_iMaxHealth", value);
	SetEntityHealth(client, RoundToNearest(value));
	if (GetConVarFloat(cvar_sr_debug) == 1.0)
	{
		PrintToServer("[SR] Survivor starts with %f health points.", value);
		LogMessage("[SR] Survivor starts with %f health points.", value);
	}
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
	SetEntityRenderColor(survivor, 255, 255, 255, 255);
	int sprite_index = EntRefToEntIndex(sprite);
	if(IsValidEntity(sprite_index))
	{
		AcceptEntityInput(sprite_index, "HideSprite");
		AcceptEntityInput(sprite_index, "Kill");
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
	return Plugin_Continue;
}

public Action Timer_EndRound(Handle timer)
{
	EndRound();
	return Plugin_Continue;
}

public Action Timer_SurvivorColor(Handle timer)
{
	if ((survivor_extracted == true) || (survivor == -1)) return Plugin_Continue;
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
						DispatchKeyValue(i, "glowable", "0"); 
						DispatchKeyValue(i, "glowblip", "0");
						AcceptEntityInput(i, "disableglow");
						PrintHintText(i, "[Survivor Rescue] %T", "survivor_all_hud", i, survivor_name);
					}
					if (i == survivor) PrintHintText(i, "[Survivor Rescue] %T", "survivor_indicator", i);
				}
			}
		}
	}
	return Plugin_Continue;
}

public Action Timer_SurvivorTrail(Handle timer)
{
	// RE-APPLY TRAIL TO SURVIVOR
	if ((survivor_extracted == true) || (survivor == -1)) return Plugin_Continue;
	if (GetConVarFloat(cvar_sr_trail) == 0.0) return Plugin_Continue;
	if (IsClientInGame(survivor))
	{
		if (IsPlayerAlive(survivor))
		{
			int color[4] = {80, 200, 255, 128};
			TE_SetupBeamFollow(survivor, PrecacheModel("materials/sprites/laserbeam.vmt", true), 0, 0.5, 0.5, 0.5, 1, color);
			TE_SendToAll();
		}
	}
	return Plugin_Continue;
}