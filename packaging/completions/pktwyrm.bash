# bash completion for pktwyrm (PacketWyrm CLI)
# Install to /usr/share/bash-completion/completions/pktwyrm
#
# Verbs and flags are kept in sync with `pktwyrm --help`. Re-check that output
# when the CLI grows new verbs.

_pktwyrm()
{
    local cur prev words cword
    _init_completion 2>/dev/null || {
        cur="${COMP_WORDS[COMP_CWORD]}"
        prev="${COMP_WORDS[COMP_CWORD-1]}"
        cword=$COMP_CWORD
        words=("${COMP_WORDS[@]}")
    }

    # Top-level verbs (offline + online), from `pktwyrm --help`.
    local verbs="init cards ports map load flow rpc stats latency sfp tap test hist firmware version"
    local globals="--secret --env --host --socket --card --watch --json --flow --port"

    # Complete the value of a flag that takes an argument.
    case "$prev" in
        --env)
            COMPREPLY=( $(compgen -f -X '!*.@(yaml|yml)' -- "$cur") $(compgen -d -- "$cur") )
            return 0 ;;
        --socket)
            COMPREPLY=( $(compgen -f -- "$cur") )
            return 0 ;;
        --secret|--host|--card|--watch|--flow|--port)
            # freeform value, no useful completion
            return 0 ;;
    esac

    # Find the primary verb (first non-flag word after the program name).
    local i verb="" verbidx=0
    for (( i=1; i < cword; i++ )); do
        case "${words[i]}" in
            -*) ;;                                  # a flag, skip
            *) verb="${words[i]}"; verbidx=$i; break ;;
        esac
    done

    if [[ -z "$verb" ]]; then
        # No verb yet: offer verbs + globals.
        if [[ "$cur" == -* ]]; then
            COMPREPLY=( $(compgen -W "$globals" -- "$cur") )
        else
            COMPREPLY=( $(compgen -W "$verbs" -- "$cur") )
        fi
        return 0
    fi

    # Locate a sub-verb (first non-flag word after the primary verb).
    local subverb="" j
    for (( j=verbidx+1; j < cword; j++ )); do
        [[ "${words[j]}" != -* ]] && { subverb="${words[j]}"; break; }
    done

    case "$verb" in
        cards|ports|map|load)
            # These take a config.yaml path (load deploys by default; --check
            # validates offline, --socket overrides the target).
            if [[ "$cur" == -* ]]; then
                COMPREPLY=( $(compgen -W "--socket --check $globals" -- "$cur") )
            else
                COMPREPLY=( $(compgen -f -X '!*.@(yaml|yml)' -- "$cur") $(compgen -d -- "$cur") )
            fi
            ;;
        flow)
            # pktwyrm flow show <cfg> | start <id> | stop <id> | stats [--flow N]
            if [[ -z "$subverb" ]]; then
                COMPREPLY=( $(compgen -W "show start stop stats" -- "$cur") )
            elif [[ "$subverb" == "show" ]]; then
                COMPREPLY=( $(compgen -f -X '!*.@(yaml|yml)' -- "$cur") $(compgen -d -- "$cur") )
            else
                COMPREPLY=( $(compgen -W "$globals" -- "$cur") )
            fi
            ;;
        test)
            if [[ -z "$subverb" ]]; then
                COMPREPLY=( $(compgen -W "arm start stop run" -- "$cur") )
            elif [[ "$subverb" == "run" ]]; then
                COMPREPLY=( $(compgen -W "--duration --json --socket $globals" -- "$cur") )
            else
                COMPREPLY=( $(compgen -W "--json $globals" -- "$cur") )
            fi
            ;;
        firmware)
            if [[ -z "$subverb" ]]; then
                COMPREPLY=( $(compgen -W "update" -- "$cur") )
            elif [[ "$cur" == -* ]]; then
                COMPREPLY=( $(compgen -W "--card --boot --scratch" -- "$cur") )
            else
                COMPREPLY=( $(compgen -f -X '!*.bin' -- "$cur") $(compgen -d -- "$cur") )
            fi
            ;;
        init)
            COMPREPLY=( $(compgen -W "--out $globals" -- "$cur") )
            ;;
        rpc)
            if [[ -z "$subverb" ]]; then
                COMPREPLY=( $(compgen -W "version cards ports flows stats" -- "$cur") )
            else
                COMPREPLY=( $(compgen -W "$globals" -- "$cur") )
            fi
            ;;
        hist)
            if [[ -z "$subverb" ]]; then
                COMPREPLY=( $(compgen -W "latency" -- "$cur") )
            else
                COMPREPLY=( $(compgen -W "$globals" -- "$cur") )
            fi
            ;;
        stats|latency|sfp|tap)
            COMPREPLY=( $(compgen -W "$globals" -- "$cur") )
            ;;
        version)
            ;;
        *)
            COMPREPLY=( $(compgen -W "$globals" -- "$cur") )
            ;;
    esac
    return 0
}
complete -F _pktwyrm pktwyrm
