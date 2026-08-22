# shellcheck shell=bash
#
# Shared by tests/os/run.sh's reinstall pre-fill check (drives it against a real KVM guest's
# console + the wizard's own state API) and tests/stack/run.sh's fixture unit test (drives it
# against canned strings): the reinstall pre-fill verdict, #1038.
#
# A wallet-address match on the wizard's merged state alone cannot tell "the pre-fill branch
# read the target disk's previous config and published it" from "the page happens to show that
# value for some other reason" — #1038 found the battery's reinstall leg green for four
# consecutive runs while never actually exercising `prefill_from_previous_install` (pithead:2350).
# Pairing the outcome with the branch's OWN record — the exact log line it prints (pithead:2351,
# `journal+console` per pithead-firstboot.service) ONLY on the path that reads a previous
# install's answers off the target disk — makes the two tell apart, the same discrimination
# #1212 needed for hugepages (HugePages_Total alone read identically whether the sizing unit ran
# and no-opped or never ran at all).

# $1 = 1 if the console printed the pre-fill branch's own log line this boot
#      ("Found the previous installation's settings on the target disk"), else 0/empty
# $2 = 1 if the wizard's merged state carries the previous install's wallet, else 0/empty
# $3 = 1 if a password value crossed into that merged state, else 0/empty
# Prints the verdict line on stdout; exit 0 = pass, 1 = fail.
reinstall_prefill_verdict() {
    local branch_logged="$1" wallet_prefilled="$2" password_leaked="$3"
    if [ "$branch_logged" != "1" ]; then
        echo "the pre-fill branch's own log line never appeared this boot — a wallet match alone cannot prove which code path produced it (#1038)"
        return 1
    fi
    if [ "$wallet_prefilled" != "1" ]; then
        echo "the pre-fill branch ran but the previous install's wallet never reached the page"
        return 1
    fi
    if [ "$password_leaked" = "1" ]; then
        echo "a password crossed into the reinstall page's pre-filled state"
        return 1
    fi
    echo "reinstall pre-fill ran this boot and published the previous install's non-secret answers (secrets left out)"
    return 0
}
