# Editing a photo album in a chat

Long-pressing an album offers **Edit Album**: a window with the album's photos (the same list the paste preview uses), where the
user can untick photos, add photos from the gallery, change their order, edit the caption and move it above or below the pictures.
When the window is folded away, the pending changes wait in a bar that replaces the input panel (`AlbumEditInputPanelNode`) until they
are saved or thrown away.

The menu of one photo, its modes and the finger-driven scrolling are in [album-photo-context-menu.md](album-photo-context-menu.md).

Code: `ChatAlbumPhotoContextMenu.swift` (`openAlbumEditor`, `applyAlbumEdit`), `AlbumEditSession.swift`,
`AlbumEditInputPanelNode.swift`.

## What the server allows today

An album is a set of ordinary messages that share a `grouped_id`. The position of a photo is the order of its message. The API gives no
way to:

- add a message to an album that is already sent (a `grouped_id` is only created by one `sendMultiMedia` call),
- move a message inside an album,
- change the whole album in one step.

What it does allow: delete a message of the album, edit one message (its media and its text), and send a new album.

## The approach: fixed places

An album keeps the places it had. The window never lets it grow:

- The text over the album reads "Up to N photos - remove one to add another" while every place is taken, and "K photos can be added"
  while K places are free (a photo was taken away).
- The attachment button next to the caption field is hidden by default. It comes out from under the field when a photo is taken away
  (unticked), and goes back under it when there is no free place.
- What is added from the gallery goes only into the free places (the gallery button reads that the maximum is reached when more is
  chosen than there are free places).

`applyAlbumEdit` turns what the user left in the window into the smallest set of operations the server allows. The number of photos is
never more than the number of messages, so the messages are always kept:

- Messages whose photo is no longer wanted are deleted. Which ones are deleted is chosen by trying every choice and taking the one that
  needs the fewest edits, so removing one photo from the middle without any other change is a single deletion.
- A message that has to show another photo gets that photo through an edit of its media: a photo that was added is uploaded; a photo
  that comes from another message of the album is sent as a copy of its local file (not by a reference to the other message, because
  that message may be edited at the same moment and its photo may no longer be there when the reference is used).
- Moving a photo is the same thing: the two messages involved are edited to show each other's photo.
- The caption stays on the message that had it, or moves to the last remaining one. The caption position flag is written on every
  message of the album.

Because nothing is ever sent as a new album, reactions, replies and the position of the album in the history are kept.

## Limits of this approach

- A reorder or replacement is a set of independent media edits. Other users see the photos change one by one, not move.
- Each edit is its own request. If one fails, the album is left half changed.
- Photos that change places are uploaded again.
- The album can never have more photos than it had; it can only shrink or have photos replaced.
- At least one photo has to stay.
- An audio file added in the window is not saved (photos and audio cannot be in one album).

## What would make it better: server changes

The workaround exists only because the album cannot be changed as one thing. With support on the server the whole thing becomes one
atomic, cheap operation and the client logic above shrinks to a single call:

- **Append to an album**: let `sendMedia` / `sendMultiMedia` take the `grouped_id` of an existing album (or add a dedicated method), so
  new photos join the same album and the limit of fixed places goes away.
- **Reorder**: a method that takes the album's message ids in their new order (or edits the album position of a message), so photos move
  without being uploaded again.
- **One call for the whole edit**: a method such as `messages.editMultiMedia` that takes the final list of media (existing ones by
  id, new ones as uploads), the caption and its position, and applies it atomically to the group, with the result delivered to other
  clients as a single update.
- Keeping the identity of the messages (and so reactions, replies and the position in the history) when an album is changed.

None of this exists in the current API, so it is a server-side change.
