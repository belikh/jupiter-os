// jupiterOS arcade — minimal Pegasus theme for the TCx Wave kiosks.
//
// Layout:
//   ┌─────────────────────────────────────────┐
//   │            jupiterOS arcade             │  ← branded header (fixed)
//   ├─────────────────────────────────────────┤
//   │  eXoDOS  ·  eXoWin3x  ·  Steam  · ...   │  ← horizontal platform bar
//   ├─────────────────────────────────────────┤
//   │  ┌──┐ ┌──┐ ┌──┐ ┌──┐ ┌──┐               │
//   │  │  │ │  │ │  │ │  │ │  │  game grid    │  ← scrollable, wraps
//   │  └──┘ └──┘ └──┘ └──┘ └──┘               │
//   │  ...                                    │
//   └─────────────────────────────────────────┘
//
// Tap a platform to switch; tap a game to launch it. The Pegasus API is
// https://pegasus-frontend.org/docs/themes/api/ — we use the global `api`
// object (collections, currentCollection, currentGame, launchGame).
import QtQuick 2.15

FocusScope {
    id: root
    focus: true

    // Background
    Rectangle {
        anchors.fill: parent
        color: "#0d0f14"
    }

    // Branded header
    Rectangle {
        id: header
        anchors.top: parent.top
        anchors.left: parent.left
        anchors.right: parent.right
        height: 72
        color: "#161a23"
        border.color: "#2a2f3a"
        border.width: 1

        Text {
            anchors.centerIn: parent
            text: "jupiterOS arcade"
            color: "#e8eaed"
            font.pixelSize: 32
            font.bold: true
            font.family: "DejaVu Sans Mono"
        }

        // Subtle progress indicator: how many games loaded
        Text {
            anchors.right: parent.right
            anchors.rightMargin: 24
            anchors.verticalCenter: parent.verticalCenter
            text: api.allGames.length + " games"
            color: "#6b7280"
            font.pixelSize: 14
        }
    }

    // Platform bar (horizontal scrollable list of collections)
    ListView {
        id: platformBar
        anchors.top: header.bottom
        anchors.left: parent.left
        anchors.right: parent.right
        height: 64
        orientation: ListView.Horizontal
        model: api.collections
        spacing: 8
        clip: true

        delegate: Rectangle {
            width: platformLabel.width + 48
            height: 44
            anchors.verticalCenter: parent.verticalCenter
            radius: 6
            color: modelData === api.currentCollection ? "#3b82f6" : "#1f242f"
            border.color: modelData === api.currentCollection ? "#60a5fa" : "#2a2f3a"
            border.width: 1

            Text {
                id: platformLabel
                anchors.centerIn: parent
                text: modelData.name
                color: modelData === api.currentCollection ? "#ffffff" : "#9ca3af"
                font.pixelSize: 18
                font.bold: modelData === api.currentCollection
            }

            MouseArea {
                anchors.fill: parent
                onClicked: {
                    api.currentCollectionIndex = index;
                    gameGrid.positionViewAtBeginning();
                }
            }
        }
    }

    // Separator
    Rectangle {
        id: separator
        anchors.top: platformBar.bottom
        anchors.left: parent.left
        anchors.right: parent.right
        height: 1
        color: "#2a2f3a"
    }

    // Game grid
    GridView {
        id: gameGrid
        anchors.top: separator.bottom
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.bottom: parent.bottom
        anchors.margins: 16
        clip: true
        cacheBuffer: 1200

        model: api.currentCollection.games
        cellWidth: 192
        cellHeight: 192

        delegate: Item {
            width: 176
            height: 176

            Rectangle {
                anchors.fill: parent
                anchors.margins: 4
                radius: 8
                color: modelData === api.currentGame ? "#1e3a8a" : "#161a23"
                border.color: modelData === api.currentGame ? "#60a5fa" : "#2a2f3a"
                border.width: modelData === api.currentGame ? 2 : 1

                Text {
                    anchors.fill: parent
                    anchors.margins: 12
                    text: modelData.title
                    color: modelData === api.currentGame ? "#ffffff" : "#d1d5db"
                    font.pixelSize: 14
                    font.bold: modelData === api.currentGame
                    wrapMode: Text.Wrap
                    horizontalAlignment: Text.AlignHCenter
                    verticalAlignment: Text.AlignVCenter
                }

                // Developer/year subtitle if available
                Text {
                    anchors.bottom: parent.bottom
                    anchors.left: parent.left
                    anchors.right: parent.right
                    anchors.margins: 8
                    text: modelData.developer ? modelData.developer : ""
                    color: "#6b7280"
                    font.pixelSize: 10
                    horizontalAlignment: Text.AlignHCenter
                    elide: Text.ElideRight
                    visible: text.length > 0
                }
            }

            MouseArea {
                anchors.fill: parent
                onClicked: {
                    api.currentGameIndex = index;
                }
                onDoubleClicked: {
                    api.currentGameIndex = index;
                    api.launchGame(modelData);
                }
            }
        }
    }

    // Bottom help line
    Text {
        anchors.bottom: parent.bottom
        anchors.horizontalCenter: parent.horizontalCenter
        anchors.bottomMargin: 4
        text: "tap to select · double-tap to launch"
        color: "#4b5563"
        font.pixelSize: 11
    }

    // Keyboard navigation: arrow keys to move, Enter to launch
    Keys.onLeftPressed: {
        if (api.currentGameIndex > 0) api.currentGameIndex--;
    }
    Keys.onRightPressed: {
        if (api.currentGameIndex < api.currentCollection.games.length - 1) api.currentGameIndex++;
    }
    Keys.onUpPressed: {
        if (api.currentGameIndex >= 4) api.currentGameIndex -= 4;
    }
    Keys.onDownPressed: {
        if (api.currentGameIndex < api.currentCollection.games.length - 4) api.currentGameIndex += 4;
    }
    Keys.onReturnPressed: {
        if (api.currentGame) api.launchGame(api.currentGame);
    }
    Keys.onEscapePressed: {
        if (api.currentCollectionIndex > 0) api.currentCollectionIndex--;
    }
}
