# Per-photo interaction in an album

Long-pressing a photo of an album does not act on the whole message any more. It acts on that one photo, and the finger can move
to another photo without being lifted. The editing of the album is in [album-photo-editing.md](album-photo-editing.md).

Code: `ChatAlbumPhotoContextMenu.swift` (menu items, tracking, swiping), `ChatAlbumPhotoContextSource.swift` (the selection and the
card), `ChatControllerOpenMessageContextMenu.swift` (where the menu is made), and, for the finger-driven scrolling, `ContextUI` /
`ContextControllerImpl`.

## The modes

| Mode | How it starts | What the finger does |
|---|---|---|
| Photo menu on the lifted album | long press on a photo | The whole album is lifted, one photo is active ("Photo 6 of 10"). Moving over another photo makes that one active and rebuilds the menu. |
| Card of one photo | the finger stays still on a photo for a while | The album turns into one photo on a card in the middle of the screen. The finger goes up and down with a limit and settles back when lifted; a move of 70 pt up or down goes to the next or previous photo, 40 pt sideways does the same. |
| Menu of the whole album | "Whole Album" in the photo menu, or a long press that is not on a photo (for example on the caption) | The usual menu of the message, with Edit Album in place of Edit. Reply comes first, then Edit Album. |

## The menu of one photo

Reply (the reply panel says which photo, "Photo 4 of 9", and shows its thumbnail), Edit Photo, Add to Saved, Forward, Delete, Select,
Whole Album. The items that depend on rules of the regular menu (who can reply, forward or delete, copy protection) are taken from the
regular menu of that one message, so the rules stay in one place.

- **Edit Photo** is the ordinary edit of the message of that photo: the edit panel says "Edit Photo" and "Photo N of M", with the
  thumbnail on the left. The thumbnail follows the photo when it is replaced.
- **Add to Saved** forwards that photo alone, with no text, to Saved Messages, and shows the usual notice.

## Reactions

Reactions belong to the album as a whole.

- The menu of one photo has none, on the lifted album and on the card, so that moving over the photos changes nothing above the content.
- The menu of the whole album has them, including the one that opens from "Whole Album". They are not known when the photo menu is
  made, so a box (`AlbumReactionsBox`) is filled when they are, and the "Whole Album" menu reads it. The items of that menu need
  `context` and `animationCache` set, or the engine silently shows no reactions.

## Moving over a tall album

An album of many tall photos does not fit on the screen, so photos are out of reach of the finger. The engine scrolls lifted content
together with the menu, and the finger would normally drag it. That is the wrong thing while choosing a photo, so while the finger is
down on the photos of the lifted album the scrolling is driven by the finger the other way round:

- A finger that goes up brings the photos above it down to it; a finger that goes down brings the ones below up.
- The distance is the distance of the finger times `albumScrollFactor` (0.6; 1.0 is the same distance). This is the number to tune.
- The album never goes past either end, with no bounce, so a finger that goes down over the top of the album does not pull it down.
- This applies only to a finger that is down on the photos of the lifted album. A touch that starts anywhere else (the menu, the
  rest of the screen) scrolls as usual, and so does everything in the actions of the whole album, on the card, and with no finger down.
- The finger that opened the menu moves the album from its own position updates. Every other finger is followed by a small
  recognizer (`AlbumPhotoScrollDriver`) that sees every touch from its start to its end and takes none of them. Only while a touch
  that began on a photo is down is the usual scrolling switched off, and it is given back the moment that touch ends or is cancelled.
  The scrolling is therefore never left off by a missed "finger lifted" event, which an earlier version did (a finger that moved
  at once never produced one), and the clock re-applies the state every 0.1 s as a safety net.
- A finger that goes from the photos onto the menu highlights the item under it, and lifting it there runs the item. This is done
  explicitly, for the finger that opened the menu and for the others (`highlightMenu(atWindowPoint:)` and `finishMenuHighlight`),
  because the engine's own handling for the finger that opened the menu did not work every time here. Going back over the photos
  takes the highlight away.
- Menu selection is on for the whole mode: a touch that begins on a menu item slides over the menu to choose an item, as in any menu
  (also when the content is taller than the screen, where the engine would otherwise switch that off); a touch that begins anywhere
  else is not taken by it and scrolls.

### Engine API this needed

Four methods on `ContextController`, carried through `ContextControllerImpl` to `ContextControllerExtractedPresentationNode`
(other presentation nodes get a no-op default):

- `setContentScrollingDriven(_ isDriven: Bool, menuSelection: Bool)`: with `isDriven` the finger no longer scrolls the lifted
  content; with `menuSelection` a finger that is down can slide over the menu even if the content is taller than the screen.
- `scrollContent(by:)`: moves the content by a distance (positive moves it up), clamped to both ends, no bounce.
- `highlightMenu(atWindowPoint:)` and `finishMenuHighlight(performAction:)`: highlight the menu item under a window point (nothing
  for nil), and run the highlighted item or only drop the highlight.

A touch that is already down when the scroller is switched off or on is not affected by it (a scroller starts only from a new
touch), which is why the state is decided at the start of a touch.

## Things that are easy to get wrong

- Never keep "scrolling is off" as a flag that is cleared by a "finger lifted" event. Derive it from the touches that are down
  (see `AlbumPhotoScrollDriver`); events such as the end of a press are not delivered for every touch.
- The menu moves when its height changes (the content and the menu are fitted together on the screen), so rebuilding it per photo
  can move the message. This is the reason reactions were removed from the per-photo menu.
- The `Edit Photo` and `Add to Saved` icons: the bookmark picture is 30 pt, the other menu pictures 24 pt, so it is redrawn at 24.
