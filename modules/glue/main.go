package main

import (
	"fmt"
	"os"
)

func main() {
	if err := dispatch(os.Args[1:]); err != nil {
		fmt.Fprintf(os.Stderr, "%s\n", err)
		os.Exit(1)
	}
}

func dispatch(args []string) error {
	if len(args) == 0 {
		return fmt.Errorf("paxos-glue: missing command")
	}
	switch args[0] {
	case "go2rtc":
		return cmdGo2rtc(args[1:])
	case "inject":
		return cmdInject(args[1:])
	case "jellyfin-seed":
		return cmdJellyfinSeed(args[1:])
	case "jellyfin-remove":
		return cmdJellyfinRemove(args[1:])
	case "fluxer-env":
		return cmdFluxerEnv(args[1:])
	case "fluxer-turn":
		return cmdFluxerTurn(args[1:])
	case "fluxer-sso":
		return cmdFluxerSSO(args[1:])
	case "fluxer-rail":
		return cmdFluxerRail(args[1:])
	case "bazarr-auth":
		return cmdBazarrAuth(args[1:])
	case "jdownloader-api":
		return cmdJDownloaderAPI(args[1:])
	case "subuid-walk":
		return cmdSubuidWalk(args[1:])
	case "resume-env":
		return cmdResumeEnv(args[1:])
	case "opencode-config":
		return cmdOpenCodeConfig(args[1:])
	case "openwebui-call-screen":
		return cmdOpenWebUICallScreen(args[1:])
	case "openwebui-tools":
		return cmdOpenWebUITools(args[1:])
	case "openchamber-repos":
		return cmdOpenChamberRepos(args[1:])
	default:
		return fmt.Errorf("paxos-glue: unknown command %s", args[0])
	}
}

func needArgs(cmd string, args []string, n int) error {
	if len(args) != n {
		return fmt.Errorf("%s: want %d arguments, got %d", cmd, n, len(args))
	}
	return nil
}
