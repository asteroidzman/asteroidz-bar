pragma Singleton

// One popover on screen, session-wide.
//
// Each bar owns a Popover of its own -- the object cannot be shared, because a
// popup is anchored to the window it belongs to -- so "exactly one popover" is
// a rule someone has to enforce, and nothing did: opening a menu on one
// monitor and then a menu on another left BOTH up, each holding its own
// full-output click catcher and each asking for Exclusive keyboard focus,
// which only one of them can actually have. Escape then closed whichever one
// the compositor happened to favour while the other sat unanswerable.
//
// The rule lives here rather than in each bar comparing state with its
// siblings: a bar announces that it is opening, and every other bar closes.

import Quickshell
import QtQuick

Singleton {
    signal opened(var owner)
}
