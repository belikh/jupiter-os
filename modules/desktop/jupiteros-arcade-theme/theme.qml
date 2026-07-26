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
// Tap a platform to switch; tap a game to select; double-tap to launch.
//
// Pegasus API (verified against the default theme + Api.h):
//   - api.collections is an ObjectListModel* of all collections
//   - api.collections.get(i) returns a collection with .name, .games, etc.
//   - .games is itself an ObjectListModel* of Game objects
//   - Game objects have .title, .developer, .launch(), etc.
//   - There is NO api.currentCollection / api.currentGame — the theme tracks
//     selection itself (that's what the default theme's PlatformBar does).
import QtQuick 2.15

FocusScope {
    id: root
    focus: true

    // Track the currently-selected collection internally. Pegasus's API has
    // no api.currentCollection; themes own this state. Defaults to 0 (the
    // first collection, which Pegasus sets up as eXoDOS).
    property int currentCollectionIndex: 0
    readonly property var currentCollection: api.collections.count
        ? api.collections.get(currentCollectionIndex)
        : null

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
            text: api.allGames.count + " games"
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
        currentIndex: root.currentCollectionIndex
        onCurrentIndexChanged: root.currentCollectionIndex = currentIndex

        delegate: Rectangle {
            width: platformLabel.width + 48
            height: 44
            anchors.verticalCenter: parent.verticalCenter
            radius: 6
            color: ListView.isCurrentItem ? "#3b82f6" : "#1f242f"
            border.color: ListView.isCurrentItem ? "#60a5fa" : "#2a2f3a"
            border.width: 1

            Text {
                id: platformLabel
                anchors.centerIn: parent
                text: modelData.name
                color: ListView.isCurrentItem ? "#ffffff" : "#9ca3af"
                font.pixelSize: 18
                font.bold: ListView.isCurrentItem
            }

            MouseArea {
                anchors.fill: parent
                onClicked: {
                    platformBar.currentIndex = index;
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

    // Game grid — model bound to the current collection's games
    GridView {
        id: gameGrid
        anchors.top: separator.bottom
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.bottom: parent.bottom
        anchors.margins: 16
        clip: true
        cacheBuffer: 1200

        model: root.currentCollection ? root.currentCollection.games : null
        cellWidth: 192
        cellHeight: 192

        delegate: Item {
            width: 176
            height: 176

            Rectangle {
                anchors.fill: parent
                anchors.margins: 4
                radius: 8
                color: GridView.isCurrentItem ? "#1e3a8a" : "#161a23"
                border.color: GridView.isCurrentItem ? "#60a5fa" : "#2a2f3a"
                border.width: GridView.isCurrentItem ? 2 : 1

                Text {
                    anchors.fill: parent
                    anchors.margins: 12
                    text: modelData.title
                    color: GridView.isCurrentItem ? "#ffffff" : "#d1d5db"
                    font.pixelSize: 14
                    font.bold: GridView.isCurrentItem
                    wrapMode: Text.Wrap
                    horizontalAlignment: Text.AlignHCenter
                    verticalAlignment: Text.AlignVCenter
                }

                // Developer subtitle if available
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
                    gameGrid.currentIndex = index;
                }
                onDoubleClicked: {
                    gameGrid.currentIndex = index;
                    modelData.launch();
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
        if (gameGrid.currentIndex > 0) gameGrid.currentIndex--;
    }
    Keys.onRightPressed: {
        if (gameGrid.currentIndex < gameGrid.count - 1) gameGrid.currentIndex++;
    }
    Keys.onUpPressed: {
        if (gameGrid.currentIndex >= 4) gameGrid.currentIndex -= 4;
    }
    Keys.onDownPressed: {
        if (gameGrid.currentIndex < gameGrid.count - 4) gameGrid.currentIndex += 4;
    }
    Keys.onReturnPressed: {
        if (gameGrid.currentItem) {
            // Re-fetch the model entry — GridView's currentItem is the delegate,
            // not the model data. Use the index to look up via the model.
            const game = root.currentCollection.games.get(gameGrid.currentIndex);
            if (game) game.launch();
        }
    }
}
