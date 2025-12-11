#define PLUGIN_VERSION 		"1.4"

/*======================================================================================
	Change Log:

1.0 (27-Nov-2025)
	- Initial fork
	- commented out pass tank notify chat print since it has no supporting functions
1.1 (29-Nov-2025)
	- Added early tank and late tank char array for appropriate maps
1.2 (07-Dec-2025)
	- Added plugin version cvar
	- Added config file with boolean for tank spawn notify and sound
1.3 (08-Dec-2025)
	- Edited tank flow for certain maps (c8m1_apartment, c8m5_rooftop, c12m3_bridge)
1.4 (11-Dec-2025)
	- Added flow calculation for furthest survivor

======================================================================================*/

#pragma semicolon 1
#pragma newdecls required
#include <sourcemod>
#include <sdktools>    // For GameRules_GetProp();
#include <left4dhooks> // https://forums.alliedmods.net/showthread.php?t=321696
#include <colors>
#define GAMEDATA			"Tank&WitchOnEveryMap"

char mapName[64]; // Map (c8m1_apartment). Every map has a progress percentage. From 0% to 100%

bool tankIsAlive = false; // Fix for the bug with displaying the Tank spawn message
bool GenericMap, g_bMapStarted; // switch for designated map, used for flow calculation
Handle g_hVsBossBuffer; // For correct calculation of the Tank spawn percentage
ConVar g_hCvarSpawnNotify, g_hCvarSpawnSound;
bool g_bCvarSpawnNotify, g_bCvarSpawnSound;
int m_flow;
Handle g_hPlayerGetLastKnownArea, g_hPlayerGetFlowDistance, g_hTimer;
float g_fCvarTimer = 2.0; //how often is the flow check executed
float maxdist, maxflow;
//====================================================================================================
// Map list
// ====================================================================================================

char restrictedMaps[][32] =  {  // Restricted maps
	"c5m5_bridge", "c7m1_docks", "c7m3_port", "c6m3_port", "c4m5_milltown_escape", "c13m2_southpinestream","c8m5_rooftop","c8m1_apartment"
};

char earlyTankMaps[][32] =  {  // maps with 20-50% spawn
	"c11m1_greenhouse","c4m2_sugarmill_a","c5m1_waterfront","c13m1_alpinecreek","c12m3_bridge"
};

char lateTankMaps[][32] =  {  // maps with 60-70% spawn
	"c1m1_hotel"
};

// ====================================================================================================
// General info
// ====================================================================================================

public Plugin myinfo = 
{
	name = "Tank&Witch on every map", 
	author = "pa4H & Altego_SXT", 
	description = "Spawn tank and witch in every chapter", 
	version = PLUGIN_VERSION, 
	url = ""
}

// ====================================================================================================
// Forward start
// ====================================================================================================

public void OnPluginStart()
{
	// ====================================================================================================
	// GAMEDATA
	// ====================================================================================================
	
	char sPath[PLATFORM_MAX_PATH];
	BuildPath(Path_SM, sPath, sizeof(sPath), "gamedata/%s.txt", GAMEDATA);
	if( FileExists(sPath) == false ) SetFailState("\n==========\nMissing required file: \"%s\".\n==========", sPath);

	Handle hGameData = LoadGameConfigFile(GAMEDATA);
	if( hGameData == null ) SetFailState("Failed to load \"%s.txt\" gamedata.", GAMEDATA);
	
	// ====================================================================================================
	// From L4D2Direct
	// ====================================================================================================
	
	// Address TheNavMesh = GameConfGetAddress(hGameData, "TerrorNavMesh");
	// if( TheNavMesh == view_as<Address>(-1) ) SetFailState("Failed to load offset \"TheNavMesh\" address.", GAMEDATA);
	
	// int offs = GameConfGetOffset(hGameData, "TerrorNavMesh::m_fMapMaxFlowDistance");
	// if( offs == -1 ) SetFailState("Failed to load \"m_fMapMaxFlowDistance\" offset.", GAMEDATA);
	// Address g_PtrGetMapMaxFlowDistance = TheNavMesh + view_as<Address>(offs);
	
	m_flow = GameConfGetOffset(hGameData, "m_flow");
	if( m_flow == -1 ) SetFailState("Failed to load \"m_flow\" offset.", GAMEDATA);
	
	StartPrepSDKCall(SDKCall_Player);
	if( PrepSDKCall_SetFromConf(hGameData, SDKConf_Virtual, "CTerrorPlayer::GetLastKnownArea") == false )
		SetFailState("Failed to find signature: CTerrorPlayer::GetLastKnownArea");
	PrepSDKCall_SetReturnInfo(SDKType_PlainOldData, SDKPass_Plain);
	g_hPlayerGetLastKnownArea = EndPrepSDKCall();
	if( g_hPlayerGetLastKnownArea == null )
		SetFailState("Failed to create SDKCall: CTerrorPlayer::GetLastKnownArea");

	StartPrepSDKCall(SDKCall_Player);
	if( PrepSDKCall_SetFromConf(hGameData, SDKConf_Signature, "PlayerGetFlowDistance") == false )
		SetFailState("Failed to find signature: PlayerGetFlowDistance");
	PrepSDKCall_AddParameter(SDKType_PlainOldData, SDKPass_Plain);
	PrepSDKCall_SetReturnInfo(SDKType_Float, SDKPass_Plain);
	g_hPlayerGetFlowDistance = EndPrepSDKCall();
	if( g_hPlayerGetFlowDistance == null )
		SetFailState("Failed to create SDKCall: PlayerGetFlowDistance");

	delete hGameData;
	
	// ====================================================================================================
	// Cmd & event hooks & translations
	// ====================================================================================================
	
	RegConsoleCmd("sm_tank", getBossFlowsm, "");
	
	HookEvent("round_start", RoundStartEvent, EventHookMode_PostNoCopy);
	HookEvent("round_end",	Event_RoundEnd,	EventHookMode_PostNoCopy);
	HookEvent("tank_spawn", TankNotify, EventHookMode_PostNoCopy); 
	HookEvent("player_death", TankDead, EventHookMode_Pre);
	
	g_hVsBossBuffer = FindConVar("versus_boss_buffer"); // For correct calculation of the Tank spawn percentage
	
	LoadTranslations("pa4HTankSpawnNotify.phrases"); // translations/pa4HTankSpawnNotify.phrases.txt
	
	// ====================================================================================================
	// CVARS
	// ====================================================================================================
	g_hCvarSpawnNotify = CreateConVar(			"Tank_WitchOnEveryMap_SpawnNotify",			"0",				"Whether or not notify in chat that a tank has spawned.", FCVAR_NOTIFY);
	g_bCvarSpawnNotify = g_hCvarSpawnNotify.BoolValue;
	g_hCvarSpawnSound = CreateConVar(			"Tank_WitchOnEveryMap_SpawnSound",			"0",				"Whether or not notify with a sound effect that a tank has spawned.", FCVAR_NOTIFY);
	g_bCvarSpawnSound = g_hCvarSpawnSound.BoolValue;
	CreateConVar(								"Tank_WitchOnEveryMap_version",			PLUGIN_VERSION,			"Tank&Witch every map version.", FCVAR_NOTIFY|FCVAR_DONTRECORD);
	AutoExecConfig(true,						"Tank_WitchOnEveryMap");
}

public void RoundStartEvent(Handle event, const char[] name, bool dontBroadcast) // Server started
{
	tankIsAlive = false; // Allow "Tank appeared" to be displayed in chat
	if (GameRules_GetProp("m_bInSecondHalfOfRound") == 0) { CreateTimer(0.4, AdjustBossFlow); } // After Round Start, set the Tank spawn percentage with a delay
	
	maxflow=0.0;
	delete g_hTimer;
	g_hTimer = CreateTimer(g_fCvarTimer, TimerUpdate, _, TIMER_REPEAT);
}

void Event_RoundEnd(Event event, const char[] name, bool dontBroadcast)
{
	ResetPlugin();
}

void ResetPlugin()
{
	delete g_hTimer;
}

public void OnMapStart()
{
	g_bMapStarted = true;
}

// ====================================================================================================
// Timerupdate to calculate flow
// ====================================================================================================
Action TimerUpdate(Handle timer)
{
	if( g_bMapStarted )
	{
		float dist;
		int area;
		maxdist=0.0;
		
		for( int i = 1; i <= MaxClients; i++ )
		{
			if( IsClientInGame(i) && GetClientTeam(i) == 2 && IsPlayerAlive(i) )
			{
				area = SDKCall(g_hPlayerGetLastKnownArea, i);

				if( area )
				{
					dist += view_as<float>(LoadFromAddress(view_as<Address>(area + m_flow), NumberType_Int32));
					if ( dist >= maxdist )
					{
						maxdist=dist;
					}
				}
			}
		}

		maxflow = maxdist / L4D2Direct_GetMapMaxFlowDistance(); 
		// PrintToServer("range(%d) g_iDistance(%d) dist(%f) g_fDistance(%f)", range, g_iDistance, dist, g_fDistance);
		
	}

	return Plugin_Continue;
}

public Action AdjustBossFlow(Handle timer)
{
	L4D2Direct_SetVSTankToSpawnThisRound(0, true); // We command the Director to spawn the Tank in the 1st round
	L4D2Direct_SetVSTankToSpawnThisRound(1, true); // We command in the 2nd round
	L4D2Direct_SetVSWitchToSpawnThisRound(0, true); // Witch
	L4D2Direct_SetVSWitchToSpawnThisRound(1, true);
	
	GetCurrentMap(mapName, sizeof(mapName)); //PrintToChatAll(mapName); // Get the map; //variable mapName is accessible since its function is public
	for (int i = 0; i < sizeof(restrictedMaps); i++) // Iterate over the list of restricted maps
	{
		if (StrEqual(restrictedMaps[i], mapName)) // If the current map is in the list of restricted maps
		{
			L4D2Direct_SetVSTankToSpawnThisRound(0, false); // Forbid the Tank spawn
			L4D2Direct_SetVSTankToSpawnThisRound(1, false);
			break;
		}
	}
	
	if (L4D_IsMissionFinalMap() == true) // If playing the last map.The director does not spawn the Tank on the 1st and last map
	{
		randomSpawn(false); // Set the Tank and Witch spawn percentages WITHOUT randomness
	}
	else // If playing any other map
	{
		if (GameRules_GetProp("m_bInSecondHalfOfRound") == 0) // If the first half of the round
		{
			randomSpawn(true); // Set the Tank and Witch spawn percentages randomly
		}
	}
	return Plugin_Stop;
}

public void randomSpawn(bool isRandom) // Function setting the Witch and Tank spawn percentage
{
	float rndFlowTank; // The percentage at which the Tank will appear
	float rndFlowWitch; // The percentage at which the Witch will appear
	GenericMap = true;
	
	if (isRandom) // Get a random percentage.If 0.9, it means it will be 80%. If 0.2, it means it will be 10%
	{
		rndFlowWitch = CalcFlow(GetRandomInt(20, 45)); // witch spawn does not need to be specific
		
		for (int i = 0; i < sizeof(earlyTankMaps); i++) // Iterate over the list of designated maps
		{
			if (StrEqual(earlyTankMaps[i], mapName)) // If the current map is in the list of designated maps
			{
				rndFlowTank = CalcFlow(GetRandomInt(20, 50));
				GenericMap = false;
				break;
			}
		}
		if (GenericMap) //if first loop didn't match a mapname, continue to 2nd list
		{
			for (int i = 0; i < sizeof(lateTankMaps); i++) // Iterate over the list of designated maps
			{
				if (StrEqual(lateTankMaps[i], mapName)) // If the current map is in the list of designated maps
				{
					rndFlowTank = CalcFlow(GetRandomInt(60, 70));
					GenericMap = false;
					break;
				}
			}
		}
		if (GenericMap) //if both loops didn't match a mapname, this means current map does not need early or late tank spawn
		{
			rndFlowTank = CalcFlow(GetRandomInt(50, 80));
		}
	}
	else
	{
		rndFlowTank = CalcFlow(10); // Fixed percentage
		rndFlowWitch = CalcFlow(10);
	}
	
	// What are the 1st and 2nd rounds? One map is divided into two rounds.The first team entered the saferoom or died — the 2nd round begins and the teams switch places
	L4D2Direct_SetVSWitchFlowPercent(0, rndFlowWitch); // Set the map progression percentage at which the Witch will appear for the 1st round
	L4D2Direct_SetVSWitchFlowPercent(1, rndFlowWitch); // For the 2nd round
	L4D2Direct_SetVSTankFlowPercent(0, rndFlowTank); // Tank
	L4D2Direct_SetVSTankFlowPercent(1, rndFlowTank);
}

public Action getBossFlowsm(int client, int args) // Read the percentage at which the Tank/Witch will spawn and output to chat
{
	int round = GameRules_GetProp("m_bInSecondHalfOfRound");
	if (L4D2Direct_GetVSTankToSpawnThisRound(0) || L4D2Direct_GetVSTankToSpawnThisRound(1))
	{
		PrintToChat(client, "\x01Tank spawn: [\x04%.0f%%\x01]", GetTankFlow(round) * 100); // Tank spawn: [49%]
	}
	else
	{
		PrintToChat(client, "\x01Tank spawn: [\x04None\x01]"); // Tank spawn: [None]
	}
	
	PrintToChat(client, "\x01Witch spawn: [\x04%.0f%%\x01]", GetWitchFlow(round) * 100); // Witch spawn: [49%]
	PrintToChat(client, "\x01Furthest survivor: [\x04%.0f%%\x01]", maxflow * 100); // Furthest survivor: [49%]
	
	return Plugin_Handled;
}

public void TankNotify(Event event, const char[] name, bool dontBroadcast) // Tank appeared!
{
	int client = GetClientOfUserId(event.GetInt("userid"));
	if (!tankIsAlive)
	{
		tankIsAlive = true; // So the message is not displayed twice
		if (g_bCvarSpawnSound == true)
		{
			PrecacheSound("ui/pickup_secret01.wav");
			EmitSoundToAll("ui/pickup_secret01.wav");
		}
		if (g_bCvarSpawnNotify == true)
		{
			if (IsFakeClient(client)) 
			{
				CPrintToChatAll("%t", "TankIsHereBOT");
			}
			else 
			{
				for (int i = 1; i <= MaxClients; i++)
				{
					if (IsValidClient(i))
					{		
						CPrintToChat(i, "%t", "TankIsHere", client);
					}
				}
			}
		}
	}
}

public void TankDead(Event event, const char[] name, bool dontBroadcast)
{
	int victim = GetClientOfUserId(event.GetInt("userid"));
	if (victim != 0 && GetClientTeam(victim) == 3) // Infected is dead
	{
		int zClass = GetEntProp(victim, Prop_Send, "m_zombieClass"); // Smoker 1, Boomer 2, Hunter 3, Spitter 4, Jockey 5, Charger 6, Witch 7, Tank 8
		if (zClass == 8) {  // Tank
			tankIsAlive = false;
		}
	}
}

float CalcFlow(int per)
{
	return ((float(per) + 0.01) / 100.0) + GetConVarFloat(g_hVsBossBuffer) / L4D2Direct_GetMapMaxFlowDistance();
}

float GetTankFlow(int round)
{
	return L4D2Direct_GetVSTankFlowPercent(round) - GetConVarFloat(g_hVsBossBuffer) / L4D2Direct_GetMapMaxFlowDistance();
}

float GetWitchFlow(int round)
{
	return L4D2Direct_GetVSWitchFlowPercent(round) - GetConVarFloat(g_hVsBossBuffer) / L4D2Direct_GetMapMaxFlowDistance();
}

stock float map(float x, float in_min, float in_max, float out_min, float out_max) // Proportion
{
	return (x - in_min) * (out_max - out_min) / (in_max - in_min) + out_min;
}

stock bool IsValidClient(int client)
{
	if (client > 0 && client <= MaxClients && IsClientInGame(client) && IsClientConnected(client) && !IsFakeClient(client)) {
		return true;
	}
	return false;
}

// Editing the map's vscript
public Action L4D_OnGetScriptValueInt(const char[] key, int &retVal)
{
	int val = retVal;
	if (StrEqual(key, "ProhibitBosses")) {
		val = 0;
	}
	if (StrEqual(key, "DisallowThreatType")) {
		val = 0;
	}
	if (StrEqual(key, "TankLimit")) {
		val = 1;
	}
	if (StrEqual(key, "WitchLimit")) {
		val = 1;
	}
	
	if (val != retVal) {
		retVal = val;
		return Plugin_Handled;
	}
	return Plugin_Continue;
} 