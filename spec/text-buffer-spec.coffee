fs = require 'fs-plus'
{join} = require 'path'
temp = require 'temp'
{File} = require 'pathwatcher'
Random = require 'random-seed'
Point = require '../src/point'
Range = require '../src/range'
iconv = require 'iconv-lite'
TextBuffer = require '../src/text-buffer'
SampleText = fs.readFileSync(join(__dirname, 'fixtures', 'sample.js'), 'utf8')

describe "TextBuffer", ->
  buffer = null

  beforeEach ->
    temp.track()
    jasmine.addCustomEqualityTester(require("underscore-plus").isEqual)
    # When running specs in Atom, setTimeout is spied on by default.
    jasmine.useRealClock?()

  afterEach ->
    buffer?.destroy()
    buffer = null

  describe "construction", ->
    it "can be constructed empty", ->
      buffer = new TextBuffer
      expect(buffer.getLineCount()).toBe 1
      expect(buffer.getText()).toBe ''
      expect(buffer.lineForRow(0)).toBe ''
      expect(buffer.lineEndingForRow(0)).toBe ''

    it "can be constructed with initial text containing no trailing newline", ->
      text = "hello\nworld\r\nhow are you doing?\rlast"
      buffer = new TextBuffer(text)
      expect(buffer.getLineCount()).toBe 4
      expect(buffer.getText()).toBe text
      expect(buffer.lineForRow(0)).toBe 'hello'
      expect(buffer.lineEndingForRow(0)).toBe '\n'
      expect(buffer.lineForRow(1)).toBe 'world'
      expect(buffer.lineEndingForRow(1)).toBe '\r\n'
      expect(buffer.lineForRow(2)).toBe 'how are you doing?'
      expect(buffer.lineEndingForRow(2)).toBe '\r'
      expect(buffer.lineForRow(3)).toBe 'last'
      expect(buffer.lineEndingForRow(3)).toBe ''

    it "can be constructed with initial text containing a trailing newline", ->
      text = "first\n"
      buffer = new TextBuffer(text)
      expect(buffer.getLineCount()).toBe 2
      expect(buffer.getText()).toBe text
      expect(buffer.lineForRow(0)).toBe 'first'
      expect(buffer.lineEndingForRow(0)).toBe '\n'
      expect(buffer.lineForRow(1)).toBe ''
      expect(buffer.lineEndingForRow(1)).toBe ''

    it "automatically assigns a unique identifier to new buffers", ->
      bufferIds = [0..16].map(-> new TextBuffer().getId())
      uniqueBufferIds = new Set(bufferIds)

      expect(uniqueBufferIds.size).toBe(bufferIds.length)

  describe "::setTextInRange(range, text)", ->
    beforeEach ->
      buffer = new TextBuffer("hello\nworld\r\nhow are you doing?")

    it "can replace text on a single line with a standard newline", ->
      buffer.setTextInRange([[0, 2], [0, 4]], "y y")
      expect(buffer.getText()).toEqual "hey yo\nworld\r\nhow are you doing?"

    it "can replace text on a single line with a carriage-return/newline", ->
      buffer.setTextInRange([[1, 3], [1, 5]], "ms")
      expect(buffer.getText()).toEqual "hello\nworms\r\nhow are you doing?"

    it "can replace text in a region spanning multiple lines, ending on the last line", ->
      buffer.setTextInRange([[0, 2], [2, 3]], "y there\r\ncat\nwhat", normalizeLineEndings: false)
      expect(buffer.getText()).toEqual "hey there\r\ncat\nwhat are you doing?"

    it "can replace text in a region spanning multiple lines, ending with a carriage-return/newline", ->
      buffer.setTextInRange([[0, 2], [1, 3]], "y\nyou're o", normalizeLineEndings: false)
      expect(buffer.getText()).toEqual "hey\nyou're old\r\nhow are you doing?"

    describe "before a change", ->
      it "notifies ::onWillChange observers with the relevant details", ->
        changes = []
        buffer.onWillChange (change) ->
          expect(buffer.getText()).toBe "hello\nworld\r\nhow are you doing?"
          changes.push(change)

        buffer.setTextInRange([[0, 2], [2, 3]], "y there\r\ncat\nwhat", normalizeLineEndings: false)
        expect(changes).toEqual [{
          oldRange: [[0, 2], [2, 3]]
          newRange: [[0, 2], [2, 4]]
          oldText: "llo\nworld\r\nhow"
          newText: "y there\r\ncat\nwhat"
          eventId: 1
        }]

    describe "after a change", ->
      it "notifies, in order, decoration layers, display layers, ::onDidChange observers and display layer ::onDidChangeSync observers with the relevant details", ->
        events = []
        textDecorationLayer1 = {bufferDidChange: (e) -> events.push({source: textDecorationLayer1, event: e})}
        textDecorationLayer2 = {bufferDidChange: (e) -> events.push({source: textDecorationLayer2, event: e})}
        displayLayer1 = buffer.addDisplayLayer()
        displayLayer2 = buffer.addDisplayLayer()
        spyOn(displayLayer1, 'bufferDidChange').and.callFake (e) ->
          events.push({source: displayLayer1, event: e})
          DisplayLayer.prototype.bufferDidChange.call(displayLayer1, e)
        spyOn(displayLayer2, 'bufferDidChange').and.callFake (e) ->
          events.push({source: displayLayer2, event: e})
          DisplayLayer.prototype.bufferDidChange.call(displayLayer2, e)
        buffer.onDidChange (e) -> events.push({source: buffer, event: e})
        buffer.registerTextDecorationLayer(textDecorationLayer1)
        buffer.registerTextDecorationLayer(textDecorationLayer1) # insert a duplicate decoration layer
        buffer.registerTextDecorationLayer(textDecorationLayer2)

        disposable = displayLayer1.onDidChangeSync ->
          disposable.dispose()
          buffer.setTextInRange([[1, 1], [1, 2]], "abc", normalizeLineEndings: false)
        buffer.setTextInRange([[0, 2], [2, 3]], "y there\r\ncat\nwhat", normalizeLineEndings: false)

        changeEvent1 = {
          oldRange: [[0, 2], [2, 3]], newRange: [[0, 2], [2, 4]]
          oldText: "llo\nworld\r\nhow", newText: "y there\r\ncat\nwhat",
          eventId: 1
        }
        changeEvent2 = {
          oldRange: [[1, 1], [1, 2]], newRange: [[1, 1], [1, 4]]
          oldText: "a", newText: "abc",
          eventId: 2
        }
        expect(events).toEqual [
          {source: textDecorationLayer1, event: changeEvent1},
          {source: textDecorationLayer2, event: changeEvent1},
          {source: displayLayer1, event: changeEvent1},
          {source: displayLayer2, event: changeEvent1},
          {source: buffer, event: changeEvent1},

          {source: textDecorationLayer1, event: changeEvent2},
          {source: textDecorationLayer2, event: changeEvent2},
          {source: displayLayer1, event: changeEvent2},
          {source: displayLayer2, event: changeEvent2},
          {source: buffer, event: changeEvent2}
        ]

    it "returns the newRange of the change", ->
      expect(buffer.setTextInRange([[0, 2], [2, 3]], "y there\r\ncat\nwhat"), normalizeLineEndings: false).toEqual [[0, 2], [2, 4]]

    it "clips the given range", ->
      buffer.setTextInRange([[-1, -1], [0, 1]], "y")
      buffer.setTextInRange([[0, 10], [0, 100]], "w")
      expect(buffer.lineForRow(0)).toBe "yellow"

    it "preserves the line endings of existing lines", ->
      buffer.setTextInRange([[0, 1], [0, 2]], 'o')
      expect(buffer.lineEndingForRow(0)).toBe '\n'
      buffer.setTextInRange([[1, 1], [1, 3]], 'i')
      expect(buffer.lineEndingForRow(1)).toBe '\r\n'

    it "freezes change event ranges", ->
      changedOldRange = null
      changedNewRange = null
      buffer.onDidChange ({oldRange, newRange}) ->
        oldRange.start = Point(0, 3)
        oldRange.start.row = 1
        newRange.start = Point(4, 4)
        newRange.end.row = 2
        changedOldRange = oldRange
        changedNewRange = newRange

      buffer.setTextInRange(Range(Point(0, 2), Point(0, 4)), "y y")

      expect(changedOldRange).toEqual([[0, 2], [0, 4]])
      expect(changedNewRange).toEqual([[0, 2], [0, 5]])

    describe "when the undo option is 'skip'", ->
      it "replaces the contents of the buffer with the given text", ->
        buffer.setTextInRange([[0, 0], [0, 1]], "y")
        buffer.setTextInRange([[0, 10], [0, 100]], "w", {undo: 'skip'})
        expect(buffer.lineForRow(0)).toBe "yellow"

        expect(buffer.undo()).toBe true
        expect(buffer.lineForRow(0)).toBe "hellow"

    describe "when the normalizeLineEndings argument is true (the default)", ->
      describe "when the range's start row has a line ending", ->
        it "normalizes inserted line endings to match the line ending of the range's start row", ->
          changeEvents = []
          buffer.onDidChange (e) -> changeEvents.push(e)

          expect(buffer.lineEndingForRow(0)).toBe '\n'
          buffer.setTextInRange([[0, 2], [0, 5]], "y\r\nthere\r\ncrazy")
          expect(buffer.lineEndingForRow(0)).toBe '\n'
          expect(buffer.lineEndingForRow(1)).toBe '\n'
          expect(buffer.lineEndingForRow(2)).toBe '\n'
          expect(changeEvents[0].newText).toBe "y\nthere\ncrazy"

          expect(buffer.lineEndingForRow(3)).toBe '\r\n'
          buffer.setTextInRange([[3, 3], [4, Infinity]], "ms\ndo you\r\nlike\ndirt")
          expect(buffer.lineEndingForRow(3)).toBe '\r\n'
          expect(buffer.lineEndingForRow(4)).toBe '\r\n'
          expect(buffer.lineEndingForRow(5)).toBe '\r\n'
          expect(buffer.lineEndingForRow(6)).toBe ''
          expect(changeEvents[1].newText).toBe "ms\r\ndo you\r\nlike\r\ndirt"

      describe "when the range's start row has no line ending (because it's the last line of the buffer)", ->
        describe "when the buffer contains no newlines", ->
          it "honors the newlines in the inserted text", ->
            buffer = new TextBuffer("hello")
            buffer.setTextInRange([[0, 2], [0, Infinity]], "hey\r\nthere\nworld")
            expect(buffer.lineEndingForRow(0)).toBe '\r\n'
            expect(buffer.lineEndingForRow(1)).toBe '\n'
            expect(buffer.lineEndingForRow(2)).toBe ''

        describe "when the buffer contains newlines", ->
          it "normalizes inserted line endings to match the line ending of the penultimate row", ->
            expect(buffer.lineEndingForRow(1)).toBe '\r\n'
            buffer.setTextInRange([[2, 0], [2, Infinity]], "what\ndo\r\nyou\nwant?")
            expect(buffer.lineEndingForRow(2)).toBe '\r\n'
            expect(buffer.lineEndingForRow(3)).toBe '\r\n'
            expect(buffer.lineEndingForRow(4)).toBe '\r\n'
            expect(buffer.lineEndingForRow(5)).toBe ''

    describe "when the normalizeLineEndings argument is false", ->
      it "honors the newlines in the inserted text", ->
        buffer.setTextInRange([[1, 0], [1, 5]], "moon\norbiting\r\nhappily\nthere", {normalizeLineEndings: false})
        expect(buffer.lineEndingForRow(1)).toBe '\n'
        expect(buffer.lineEndingForRow(2)).toBe '\r\n'
        expect(buffer.lineEndingForRow(3)).toBe '\n'
        expect(buffer.lineEndingForRow(4)).toBe '\r\n'
        expect(buffer.lineEndingForRow(5)).toBe ''

  describe "::setText(text)", ->
    it "replaces the contents of the buffer with the given text", ->
      buffer = new TextBuffer("hello\nworld\r\nyou are cool")
      buffer.setText("goodnight\r\nmoon\nit's been good")
      expect(buffer.getText()).toBe "goodnight\r\nmoon\nit's been good"
      buffer.undo()
      expect(buffer.getText()).toBe "hello\nworld\r\nyou are cool"

  describe "::insert(position, text, normalizeNewlinesn)", ->
    it "inserts text at the given position", ->
      buffer = new TextBuffer("hello world")
      buffer.insert([0, 5], " there")
      expect(buffer.getText()).toBe "hello there world"

    it "honors the normalizeNewlines option", ->
      buffer = new TextBuffer("hello\nworld")
      buffer.insert([0, 5], "\r\nthere\r\nlittle", normalizeLineEndings: false)
      expect(buffer.getText()).toBe "hello\r\nthere\r\nlittle\nworld"

  describe "::append(text, normalizeNewlines)", ->
    it "appends text to the end of the buffer", ->
      buffer = new TextBuffer("hello world")
      buffer.append(", how are you?")
      expect(buffer.getText()).toBe "hello world, how are you?"

    it "honors the normalizeNewlines option", ->
      buffer = new TextBuffer("hello\nworld")
      buffer.append("\r\nhow\r\nare\nyou?", normalizeLineEndings: false)
      expect(buffer.getText()).toBe "hello\nworld\r\nhow\r\nare\nyou?"

  describe "::delete(range)", ->
    it "deletes text in the given range", ->
      buffer = new TextBuffer("hello world")
      buffer.delete([[0, 5], [0, 11]])
      expect(buffer.getText()).toBe "hello"

  describe "::deleteRows(startRow, endRow)", ->
    beforeEach ->
      buffer = new TextBuffer("first\nsecond\nthird\nlast")

    describe "when the endRow is less than the last row of the buffer", ->
      it "deletes the specified rows", ->
        buffer.deleteRows(1, 2)
        expect(buffer.getText()).toBe "first\nlast"
        buffer.deleteRows(0, 0)
        expect(buffer.getText()).toBe "last"

    describe "when the endRow is the last row of the buffer", ->
      it "deletes the specified rows", ->
        buffer.deleteRows(2, 3)
        expect(buffer.getText()).toBe "first\nsecond"
        buffer.deleteRows(0, 1)
        expect(buffer.getText()).toBe ""

    it "clips the given row range", ->
      buffer.deleteRows(-1, 0)
      expect(buffer.getText()).toBe "second\nthird\nlast"
      buffer.deleteRows(1, 5)
      expect(buffer.getText()).toBe "second"

      buffer.deleteRows(-2, -1)
      expect(buffer.getText()).toBe "second"
      buffer.deleteRows(1, 2)
      expect(buffer.getText()).toBe "second"

    it "handles out of order row ranges", ->
      buffer.deleteRows(2, 1)
      expect(buffer.getText()).toBe "first\nlast"

  describe "::getText()", ->
    it "returns the contents of the buffer as a single string", ->
      buffer = new TextBuffer("hello\nworld\r\nhow are you?")
      expect(buffer.getText()).toBe "hello\nworld\r\nhow are you?"
      buffer.setTextInRange([[1, 0], [1, 5]], "mom")
      expect(buffer.getText()).toBe "hello\nmom\r\nhow are you?"

  describe "::undo() and ::redo()", ->
    beforeEach ->
      buffer = new TextBuffer(text: "hello\nworld\r\nhow are you doing?")

    it "undoes and redoes multiple changes", ->
      buffer.setTextInRange([[0, 5], [0, 5]], " there")
      buffer.setTextInRange([[1, 0], [1, 5]], "friend")
      expect(buffer.getText()).toBe "hello there\nfriend\r\nhow are you doing?"

      buffer.undo()
      expect(buffer.getText()).toBe "hello there\nworld\r\nhow are you doing?"

      buffer.undo()
      expect(buffer.getText()).toBe "hello\nworld\r\nhow are you doing?"

      buffer.undo()
      expect(buffer.getText()).toBe "hello\nworld\r\nhow are you doing?"

      buffer.redo()
      expect(buffer.getText()).toBe "hello there\nworld\r\nhow are you doing?"

      buffer.undo()
      expect(buffer.getText()).toBe "hello\nworld\r\nhow are you doing?"

      buffer.redo()
      buffer.redo()
      expect(buffer.getText()).toBe "hello there\nfriend\r\nhow are you doing?"

      buffer.redo()
      expect(buffer.getText()).toBe "hello there\nfriend\r\nhow are you doing?"

    it "clears the redo stack upon a fresh change", ->
      buffer.setTextInRange([[0, 5], [0, 5]], " there")
      buffer.setTextInRange([[1, 0], [1, 5]], "friend")
      expect(buffer.getText()).toBe "hello there\nfriend\r\nhow are you doing?"

      buffer.undo()
      expect(buffer.getText()).toBe "hello there\nworld\r\nhow are you doing?"

      buffer.setTextInRange([[1, 3], [1, 5]], "m")
      expect(buffer.getText()).toBe "hello there\nworm\r\nhow are you doing?"

      buffer.redo()
      expect(buffer.getText()).toBe "hello there\nworm\r\nhow are you doing?"

      buffer.undo()
      expect(buffer.getText()).toBe "hello there\nworld\r\nhow are you doing?"

      buffer.undo()
      expect(buffer.getText()).toBe "hello\nworld\r\nhow are you doing?"

    it "does not allow the undo stack to grow without bound", ->
      buffer = new TextBuffer(maxUndoEntries: 12)

      # Each transaction is treated as a single undo entry. We can undo up
      # to 12 of them.
      buffer.setText("")
      buffer.clearUndoStack()
      for i in [0...13]
        buffer.transact ->
          buffer.append(String(i))
          buffer.append("\n")
      expect(buffer.getLineCount()).toBe 14

      undoCount = 0
      undoCount++ while buffer.undo()
      expect(undoCount).toBe 12
      expect(buffer.getText()).toBe '0\n'

  describe "transactions", ->
    now = null

    beforeEach ->
      now = 0
      spyOn(Date, 'now').and.callFake -> now

      buffer = new TextBuffer(text: "hello\nworld\r\nhow are you doing?")
      buffer.setTextInRange([[1, 3], [1, 5]], 'ms')

    describe "::transact(groupingInterval, fn)", ->
      it "groups all operations in the given function in a single transaction", ->
        buffer.transact ->
          buffer.setTextInRange([[0, 2], [0, 5]], "y")
          buffer.transact ->
            buffer.setTextInRange([[2, 13], [2, 14]], "igg")

        expect(buffer.getText()).toBe "hey\nworms\r\nhow are you digging?"
        buffer.undo()
        expect(buffer.getText()).toBe "hello\nworms\r\nhow are you doing?"
        buffer.undo()
        expect(buffer.getText()).toBe "hello\nworld\r\nhow are you doing?"

      it "halts execution of the function if the transaction is aborted", ->
        innerContinued = false
        outerContinued = false

        buffer.transact ->
          buffer.setTextInRange([[0, 2], [0, 5]], "y")
          buffer.transact ->
            buffer.setTextInRange([[2, 13], [2, 14]], "igg")
            buffer.abortTransaction()
            innerContinued = true
          outerContinued = true

        expect(innerContinued).toBe false
        expect(outerContinued).toBe true
        expect(buffer.getText()).toBe "hey\nworms\r\nhow are you doing?"

      it "groups all operations performed within the given function into a single undo/redo operation", ->
        buffer.transact ->
          buffer.setTextInRange([[0, 2], [0, 5]], "y")
          buffer.setTextInRange([[2, 13], [2, 14]], "igg")

        expect(buffer.getText()).toBe "hey\nworms\r\nhow are you digging?"

        # subsequent changes are not included in the transaction
        buffer.setTextInRange([[1, 0], [1, 0]], "little ")
        buffer.undo()
        expect(buffer.getText()).toBe "hey\nworms\r\nhow are you digging?"

        # this should undo all changes in the transaction
        buffer.undo()
        expect(buffer.getText()).toBe "hello\nworms\r\nhow are you doing?"

        # previous changes are not included in the transaction
        buffer.undo()
        expect(buffer.getText()).toBe "hello\nworld\r\nhow are you doing?"

        buffer.redo()
        expect(buffer.getText()).toBe "hello\nworms\r\nhow are you doing?"

        # this should redo all changes in the transaction
        buffer.redo()
        expect(buffer.getText()).toBe "hey\nworms\r\nhow are you digging?"

        # this should redo the change following the transaction
        buffer.redo()
        expect(buffer.getText()).toBe "hey\nlittle worms\r\nhow are you digging?"

      it "does not push the transaction to the undo stack if it is empty", ->
        buffer.transact ->
        buffer.undo()
        expect(buffer.getText()).toBe "hello\nworld\r\nhow are you doing?"

        buffer.redo()
        buffer.transact -> buffer.abortTransaction()
        buffer.undo()
        expect(buffer.getText()).toBe "hello\nworld\r\nhow are you doing?"

      it "halts execution undoes all operations since the beginning of the transaction if ::abortTransaction() is called", ->
        continuedPastAbort = false
        buffer.transact ->
          buffer.setTextInRange([[0, 2], [0, 5]], "y")
          buffer.setTextInRange([[2, 13], [2, 14]], "igg")
          buffer.abortTransaction()
          continuedPastAbort = true

        expect(continuedPastAbort).toBe false

        expect(buffer.getText()).toBe "hello\nworms\r\nhow are you doing?"

        buffer.undo()
        expect(buffer.getText()).toBe "hello\nworld\r\nhow are you doing?"

        buffer.redo()
        expect(buffer.getText()).toBe "hello\nworms\r\nhow are you doing?"

        buffer.redo()
        expect(buffer.getText()).toBe "hello\nworms\r\nhow are you doing?"

      it "preserves the redo stack until a content change occurs", ->
        buffer.undo()
        expect(buffer.getText()).toBe "hello\nworld\r\nhow are you doing?"

        # no changes occur in this transaction before aborting
        buffer.transact ->
          buffer.abortTransaction()
          buffer.setTextInRange([[0, 0], [0, 5]], "hey")

        buffer.redo()
        expect(buffer.getText()).toBe "hello\nworms\r\nhow are you doing?"

        buffer.undo()
        expect(buffer.getText()).toBe "hello\nworld\r\nhow are you doing?"

        buffer.transact ->
          buffer.setTextInRange([[0, 0], [0, 5]], "hey")
          buffer.abortTransaction()
        expect(buffer.getText()).toBe "hello\nworld\r\nhow are you doing?"

        buffer.redo()
        expect(buffer.getText()).toBe "hello\nworld\r\nhow are you doing?"

      it "allows nested transactions", ->
        expect(buffer.getText()).toBe "hello\nworms\r\nhow are you doing?"

        buffer.transact ->
          buffer.setTextInRange([[0, 2], [0, 5]], "y")
          buffer.transact ->
            buffer.setTextInRange([[2, 13], [2, 14]], "igg")
            buffer.setTextInRange([[2, 18], [2, 19]], "'")
          expect(buffer.getText()).toBe "hey\nworms\r\nhow are you diggin'?"
          buffer.undo()
          expect(buffer.getText()).toBe "hey\nworms\r\nhow are you doing?"
          buffer.redo()
          expect(buffer.getText()).toBe "hey\nworms\r\nhow are you diggin'?"

        buffer.undo()
        expect(buffer.getText()).toBe "hello\nworms\r\nhow are you doing?"

        buffer.redo()
        expect(buffer.getText()).toBe "hey\nworms\r\nhow are you diggin'?"

        buffer.undo()
        buffer.undo()
        expect(buffer.getText()).toBe "hello\nworld\r\nhow are you doing?"

      it "groups adjacent transactions within each other's grouping intervals", ->
        buffer.transact 101, -> buffer.setTextInRange([[0, 2], [0, 5]], "y")

        now += 100
        buffer.transact 201, -> buffer.setTextInRange([[0, 3], [0, 3]], "yy")

        now += 200
        buffer.transact 201, -> buffer.setTextInRange([[0, 5], [0, 5]], "yy")

        # not grouped because the previous transaction's grouping interval
        # is only 200ms and we've advanced 300ms
        now += 300
        buffer.transact 301, -> buffer.setTextInRange([[0, 7], [0, 7]], "!!")

        expect(buffer.getText()).toBe "heyyyyy!!\nworms\r\nhow are you doing?"

        buffer.undo()
        expect(buffer.getText()).toBe "heyyyyy\nworms\r\nhow are you doing?"

        buffer.undo()
        expect(buffer.getText()).toBe "hello\nworms\r\nhow are you doing?"

        buffer.redo()
        expect(buffer.getText()).toBe "heyyyyy\nworms\r\nhow are you doing?"

        buffer.redo()
        expect(buffer.getText()).toBe "heyyyyy!!\nworms\r\nhow are you doing?"

      it "allows undo/redo within transactions, but not beyond the start of the containing transaction", ->
        buffer.setText("")

        buffer.append("a")

        buffer.transact ->
          buffer.append("b")
          buffer.transact -> buffer.append("c")
          buffer.append("d")

          expect(buffer.undo()).toBe true
          expect(buffer.getText()).toBe "abc"

          expect(buffer.undo()).toBe true
          expect(buffer.getText()).toBe "ab"

          expect(buffer.undo()).toBe true
          expect(buffer.getText()).toBe "a"

          expect(buffer.undo()).toBe false
          expect(buffer.getText()).toBe "a"

          expect(buffer.redo()).toBe true
          expect(buffer.getText()).toBe "ab"

          expect(buffer.redo()).toBe true
          expect(buffer.getText()).toBe "abc"

          expect(buffer.redo()).toBe true
          expect(buffer.getText()).toBe "abcd"

          expect(buffer.redo()).toBe false
          expect(buffer.getText()).toBe "abcd"

        expect(buffer.undo()).toBe true
        expect(buffer.getText()).toBe "a"

  describe "checkpoints", ->
    beforeEach ->
      buffer = new TextBuffer

    describe "::getChangesSinceCheckpoint(checkpoint)", ->
      it "returns a list of changes that have been made since the checkpoint", ->
        buffer.setText('abc\ndef\nghi\njkl\n')
        buffer.append("mno\n")
        checkpoint = buffer.createCheckpoint()
        buffer.transact ->
          buffer.append('pqr\n')
          buffer.append('stu\n')
        buffer.append('vwx\n')
        buffer.setTextInRange([[1, 0], [1, 2]], 'yz')

        expect(buffer.getText()).toBe 'abc\nyzf\nghi\njkl\nmno\npqr\nstu\nvwx\n'
        expect(buffer.getChangesSinceCheckpoint(checkpoint)).toEqual [
          {start: [1, 0], oldExtent: [0, 2], newExtent: [0, 2], newText: 'yz'},
          {start: [5, 0], oldExtent: [0, 0], newExtent: [3, 0], newText: 'pqr\nstu\nvwx\n'}
        ]

      it "returns an empty list of changes when no change has been made since the checkpoint", ->
        checkpoint = buffer.createCheckpoint()
        expect(buffer.getChangesSinceCheckpoint(checkpoint)).toEqual []

      it "returns an empty list of changes when the checkpoint doesn't exist", ->
        buffer.transact ->
          buffer.append('abc\n')
          buffer.append('def\n')
        buffer.append('ghi\n')
        expect(buffer.getChangesSinceCheckpoint(-1)).toEqual []

    describe "::revertToCheckpoint(checkpoint)", ->
      it "undoes all changes following the checkpoint", ->
        buffer.append("hello")
        checkpoint = buffer.createCheckpoint()

        buffer.transact ->
          buffer.append("\n")
          buffer.append("world")

        buffer.append("\n")
        buffer.append("how are you?")

        result = buffer.revertToCheckpoint(checkpoint)
        expect(result).toBe(true)
        expect(buffer.getText()).toBe("hello")

        buffer.redo()
        expect(buffer.getText()).toBe("hello")

    describe "::groupChangesSinceCheckpoint(checkpoint)", ->
      it "combines all changes since the checkpoint into a single transaction", ->
        buffer.append("one\n")
        checkpoint = buffer.createCheckpoint()
        buffer.append("two\n")
        buffer.transact ->
          buffer.append("three\n")
          buffer.append("four")

        result = buffer.groupChangesSinceCheckpoint(checkpoint)

        expect(result).toBeTruthy()
        expect(buffer.getText()).toBe """
          one
          two
          three
          four
        """

        buffer.undo()
        expect(buffer.getText()).toBe("one\n")

        buffer.redo()
        expect(buffer.getText()).toBe """
          one
          two
          three
          four
        """

      it "skips any later checkpoints when grouping changes", ->
        buffer.append("one\n")
        checkpoint = buffer.createCheckpoint()
        buffer.append("two\n")
        checkpoint2 = buffer.createCheckpoint()
        buffer.append("three")

        buffer.groupChangesSinceCheckpoint(checkpoint)
        expect(buffer.revertToCheckpoint(checkpoint2)).toBe(false)

        expect(buffer.getText()).toBe """
          one
          two
          three
        """

        buffer.undo()
        expect(buffer.getText()).toBe("one\n")

        buffer.redo()
        expect(buffer.getText()).toBe """
          one
          two
          three
        """

      it "does nothing when no changes have been made since the checkpoint", ->
        buffer.append("one\n")
        checkpoint = buffer.createCheckpoint()
        result = buffer.groupChangesSinceCheckpoint(checkpoint)
        expect(result).toBeTruthy()
        buffer.undo()
        expect(buffer.getText()).toBe ""

      it "returns false and does nothing when the checkpoint is not in the buffer's history", ->
        buffer.append("hello\n")
        checkpoint = buffer.createCheckpoint()
        buffer.undo()
        buffer.append("world")
        result = buffer.groupChangesSinceCheckpoint(checkpoint)
        expect(result).toBeFalsy()
        buffer.undo()
        expect(buffer.getText()).toBe ""

    it "skips checkpoints when undoing", ->
      buffer.append("hello")
      buffer.createCheckpoint()
      buffer.createCheckpoint()
      buffer.createCheckpoint()
      buffer.undo()
      expect(buffer.getText()).toBe("")

    it "preserves checkpoints across undo and redo", ->
      buffer.append("a")
      buffer.append("b")
      checkpoint1 = buffer.createCheckpoint()
      buffer.append("c")
      checkpoint2 = buffer.createCheckpoint()

      buffer.undo()
      expect(buffer.getText()).toBe("ab")

      buffer.redo()
      expect(buffer.getText()).toBe("abc")

      buffer.append("d")

      expect(buffer.revertToCheckpoint(checkpoint2)).toBe true
      expect(buffer.getText()).toBe("abc")
      expect(buffer.revertToCheckpoint(checkpoint1)).toBe true
      expect(buffer.getText()).toBe("ab")

    it "handles checkpoints created when there have been no changes", ->
      checkpoint = buffer.createCheckpoint()
      buffer.undo()
      buffer.append("hello")
      buffer.revertToCheckpoint(checkpoint)
      expect(buffer.getText()).toBe("")

    it "returns false when the checkpoint is not in the buffer's history", ->
      buffer.append("hello\n")
      checkpoint = buffer.createCheckpoint()
      buffer.undo()
      buffer.append("world")
      expect(buffer.revertToCheckpoint(checkpoint)).toBe(false)
      expect(buffer.getText()).toBe("world")

    it "does not allow changes based on checkpoints outside of the current transaction", ->
      checkpoint = buffer.createCheckpoint()

      buffer.append("a")

      buffer.transact ->
        expect(buffer.revertToCheckpoint(checkpoint)).toBe false
        expect(buffer.getText()).toBe "a"

        buffer.append("b")

        expect(buffer.groupChangesSinceCheckpoint(checkpoint)).toBeFalsy()

      buffer.undo()
      expect(buffer.getText()).toBe "a"

  describe "::getTextInRange(range)", ->
    it "returns the text in a given range", ->
      buffer = new TextBuffer(text: "hello\nworld\r\nhow are you doing?")
      expect(buffer.getTextInRange([[1, 1], [1, 4]])).toBe "orl"
      expect(buffer.getTextInRange([[0, 3], [2, 3]])).toBe "lo\nworld\r\nhow"
      expect(buffer.getTextInRange([[0, 0], [2, 18]])).toBe buffer.getText()

    it "clips the given range", ->
      buffer = new TextBuffer(text: "hello\nworld\r\nhow are you doing?")
      expect(buffer.getTextInRange([[-100, -100], [100, 100]])).toBe buffer.getText()

  describe "::clipPosition(position)", ->
    it "returns a valid position closest to the given position", ->
      buffer = new TextBuffer(text: "hello\nworld\r\nhow are you doing?")
      expect(buffer.clipPosition([-1, -1])).toEqual [0, 0]
      expect(buffer.clipPosition([-1, 2])).toEqual [0, 0]
      expect(buffer.clipPosition([0, -1])).toEqual [0, 0]
      expect(buffer.clipPosition([0, 20])).toEqual [0, 5]
      expect(buffer.clipPosition([1, -1])).toEqual [1, 0]
      expect(buffer.clipPosition([1, 20])).toEqual [1, 5]
      expect(buffer.clipPosition([10, 0])).toEqual [2, 18]
      expect(buffer.clipPosition([Infinity, 0])).toEqual [2, 18]

    it "throws an error when given an invalid point", ->
      buffer = new TextBuffer(text: "hello\nworld\r\nhow are you doing?")
      expect -> buffer.clipPosition([NaN, 1])
        .toThrowError("Invalid Point: (NaN, 1)")
      expect -> buffer.clipPosition([0, NaN])
        .toThrowError("Invalid Point: (0, NaN)")
      expect -> buffer.clipPosition([0, {}])
        .toThrowError("Invalid Point: (0, [object Object])")

  describe "::characterIndexForPosition(position)", ->
    beforeEach ->
      buffer = new TextBuffer(text: "zero\none\r\ntwo\nthree")

    it "returns the absolute character offset for the given position", ->
      expect(buffer.characterIndexForPosition([0, 0])).toBe 0
      expect(buffer.characterIndexForPosition([0, 1])).toBe 1
      expect(buffer.characterIndexForPosition([0, 4])).toBe 4
      expect(buffer.characterIndexForPosition([1, 0])).toBe 5
      expect(buffer.characterIndexForPosition([1, 1])).toBe 6
      expect(buffer.characterIndexForPosition([1, 3])).toBe 8
      expect(buffer.characterIndexForPosition([2, 0])).toBe 10
      expect(buffer.characterIndexForPosition([2, 1])).toBe 11
      expect(buffer.characterIndexForPosition([3, 0])).toBe 14
      expect(buffer.characterIndexForPosition([3, 5])).toBe 19

    it "clips the given position before translating", ->
      expect(buffer.characterIndexForPosition([-1, -1])).toBe 0
      expect(buffer.characterIndexForPosition([1, 100])).toBe 8
      expect(buffer.characterIndexForPosition([100, 100])).toBe 19

  describe "::positionForCharacterIndex(offset)", ->
    beforeEach ->
      buffer = new TextBuffer(text: "zero\none\r\ntwo\nthree")

    it "returns the position for the given absolute character offset", ->
      expect(buffer.positionForCharacterIndex(0)).toEqual [0, 0]
      expect(buffer.positionForCharacterIndex(1)).toEqual [0, 1]
      expect(buffer.positionForCharacterIndex(4)).toEqual [0, 4]
      expect(buffer.positionForCharacterIndex(5)).toEqual [1, 0]
      expect(buffer.positionForCharacterIndex(6)).toEqual [1, 1]
      expect(buffer.positionForCharacterIndex(8)).toEqual [1, 3]
      expect(buffer.positionForCharacterIndex(10)).toEqual [2, 0]
      expect(buffer.positionForCharacterIndex(11)).toEqual [2, 1]
      expect(buffer.positionForCharacterIndex(14)).toEqual [3, 0]
      expect(buffer.positionForCharacterIndex(19)).toEqual [3, 5]

    it "clips the given offset before translating", ->
      expect(buffer.positionForCharacterIndex(-1)).toEqual [0, 0]
      expect(buffer.positionForCharacterIndex(20)).toEqual [3, 5]

  describe "serialization", ->
    it "can serialize / deserialize the buffer along with its history", (done) ->
      bufferA = new TextBuffer(text: "hello\nworld\r\nhow are you doing?")
      bufferA.createCheckpoint()
      bufferA.setTextInRange([[0, 5], [0, 5]], " there")
      bufferA.transact -> bufferA.setTextInRange([[1, 0], [1, 5]], "friend")
      bufferA.transact ->
        bufferA.setTextInRange([[1, 0], [1, 0]], "good ")
        bufferA.append("?")
      bufferA.setTextInRange([[0, 5], [0, 5]], "oo")
      bufferA.undo()

      state = JSON.parse(JSON.stringify(bufferA.serialize()))
      bufferB = TextBuffer.deserialize(state)

      expect(bufferB.getText()).toBe "hello there\ngood friend\r\nhow are you doing??"

      bufferA.redo()
      bufferB.redo()
      expect(bufferB.getText()).toBe "hellooo there\ngood friend\r\nhow are you doing??"

      bufferA.undo()
      bufferB.undo()
      expect(bufferB.getText()).toBe "hello there\ngood friend\r\nhow are you doing??"

      bufferA.undo()
      bufferB.undo()
      expect(bufferB.getText()).toBe "hello there\nfriend\r\nhow are you doing?"

      bufferA.undo()
      bufferB.undo()
      expect(bufferB.getText()).toBe "hello there\nworld\r\nhow are you doing?"

      bufferA.undo()
      bufferB.undo()
      expect(bufferB.getText()).toBe "hello\nworld\r\nhow are you doing?"

      # Doesn't try to reload the buffer since it has no file.
      setTimeout(->
        expect(bufferB.getText()).toBe "hello\nworld\r\nhow are you doing?"
        done()
      , 50)

    it "serializes / deserializes the buffer's unique identifier", ->
      bufferA = new TextBuffer()
      bufferB = TextBuffer.deserialize(JSON.parse(JSON.stringify(bufferA.serialize())))

      expect(bufferB.getId()).toEqual(bufferA.getId())

    it "doesn't deserialize a state that was serialized with a different buffer version", ->
      bufferA = new TextBuffer()
      serializedBuffer = JSON.parse(JSON.stringify(bufferA.serialize()))
      serializedBuffer.version = 123456789

      expect(TextBuffer.deserialize(serializedBuffer)).toBeUndefined()

  describe "::getRange()", ->
    it "returns the range of the entire buffer text", ->
      buffer = new TextBuffer("abc\ndef\nghi")
      expect(buffer.getRange()).toEqual [[0, 0], [2, 3]]

  describe "::rangeForRow(row, includeNewline)", ->
    beforeEach ->
      buffer = new TextBuffer("this\nis a test\r\ntesting")

    describe "if includeNewline is false (the default)", ->
      it "returns a range from the beginning of the line to the end of the line", ->
        expect(buffer.rangeForRow(0)).toEqual([[0, 0], [0, 4]])
        expect(buffer.rangeForRow(1)).toEqual([[1, 0], [1, 9]])
        expect(buffer.rangeForRow(2)).toEqual([[2, 0], [2, 7]])

    describe "if includeNewline is true", ->
      it "returns a range from the beginning of the line to the beginning of the next (if it exists)", ->
        expect(buffer.rangeForRow(0, true)).toEqual([[0, 0], [1, 0]])
        expect(buffer.rangeForRow(1, true)).toEqual([[1, 0], [2, 0]])
        expect(buffer.rangeForRow(2, true)).toEqual([[2, 0], [2, 7]])

    describe "if the given row is out of range", ->
      it "returns the range of the nearest valid row", ->
        expect(buffer.rangeForRow(-1)).toEqual([[0, 0], [0, 4]])
        expect(buffer.rangeForRow(10)).toEqual([[2, 0], [2, 7]])

  describe "::getLines()", ->
    it "returns an array of lines in the text contents", ->
      filePath = require.resolve('./fixtures/sample.js')
      fileContents = fs.readFileSync(filePath, 'utf8')
      buffer = new TextBuffer(fileContents)
      expect(buffer.getLines().length).toBe fileContents.split("\n").length
      expect(buffer.getLines().join('\n')).toBe fileContents

  describe "::change(range, string)", ->
    changeHandler = null

    beforeEach ->
      filePath = require.resolve('./fixtures/sample.js')
      fileContents = fs.readFileSync(filePath, 'utf8')
      buffer = new TextBuffer(fileContents)
      changeHandler = jasmine.createSpy('changeHandler')
      buffer.onDidChange changeHandler

    describe "when used to insert (called with an empty range and a non-empty string)", ->
      describe "when the given string has no newlines", ->
        it "inserts the string at the location of the given range", ->
          range = [[3, 4], [3, 4]]
          buffer.setTextInRange range, "foo"

          expect(buffer.lineForRow(2)).toBe "    if (items.length <= 1) return items;"
          expect(buffer.lineForRow(3)).toBe "    foovar pivot = items.shift(), current, left = [], right = [];"
          expect(buffer.lineForRow(4)).toBe "    while(items.length > 0) {"

          expect(changeHandler).toHaveBeenCalled()
          [event] = changeHandler.calls.allArgs()[0]
          expect(event.oldRange).toEqual range
          expect(event.newRange).toEqual [[3, 4], [3, 7]]
          expect(event.oldText).toBe ""
          expect(event.newText).toBe "foo"

      describe "when the given string has newlines", ->
        it "inserts the lines at the location of the given range", ->
          range = [[3, 4], [3, 4]]

          buffer.setTextInRange range, "foo\n\nbar\nbaz"

          expect(buffer.lineForRow(2)).toBe "    if (items.length <= 1) return items;"
          expect(buffer.lineForRow(3)).toBe "    foo"
          expect(buffer.lineForRow(4)).toBe ""
          expect(buffer.lineForRow(5)).toBe "bar"
          expect(buffer.lineForRow(6)).toBe "bazvar pivot = items.shift(), current, left = [], right = [];"
          expect(buffer.lineForRow(7)).toBe "    while(items.length > 0) {"

          expect(changeHandler).toHaveBeenCalled()
          [event] = changeHandler.calls.allArgs()[0]
          expect(event.oldRange).toEqual range
          expect(event.newRange).toEqual [[3, 4], [6, 3]]
          expect(event.oldText).toBe ""
          expect(event.newText).toBe "foo\n\nbar\nbaz"

    describe "when used to remove (called with a non-empty range and an empty string)", ->
      describe "when the range is contained within a single line", ->
        it "removes the characters within the range", ->
          range = [[3, 4], [3, 7]]
          buffer.setTextInRange range, ""

          expect(buffer.lineForRow(2)).toBe "    if (items.length <= 1) return items;"
          expect(buffer.lineForRow(3)).toBe "     pivot = items.shift(), current, left = [], right = [];"
          expect(buffer.lineForRow(4)).toBe "    while(items.length > 0) {"

          expect(changeHandler).toHaveBeenCalled()
          [event] = changeHandler.calls.allArgs()[0]
          expect(event.oldRange).toEqual range
          expect(event.newRange).toEqual [[3, 4], [3, 4]]
          expect(event.oldText).toBe "var"
          expect(event.newText).toBe ""

      describe "when the range spans 2 lines", ->
        it "removes the characters within the range and joins the lines", ->
          range = [[3, 16], [4, 4]]
          buffer.setTextInRange range, ""

          expect(buffer.lineForRow(2)).toBe "    if (items.length <= 1) return items;"
          expect(buffer.lineForRow(3)).toBe "    var pivot = while(items.length > 0) {"
          expect(buffer.lineForRow(4)).toBe "      current = items.shift();"

          expect(changeHandler).toHaveBeenCalled()
          [event] = changeHandler.calls.allArgs()[0]
          expect(event.oldRange).toEqual range
          expect(event.newRange).toEqual [[3, 16], [3, 16]]
          expect(event.oldText).toBe "items.shift(), current, left = [], right = [];\n    "
          expect(event.newText).toBe ""

      describe "when the range spans more than 2 lines", ->
        it "removes the characters within the range, joining the first and last line and removing the lines in-between", ->
          buffer.setTextInRange [[3, 16], [11, 9]], ""

          expect(buffer.lineForRow(2)).toBe "    if (items.length <= 1) return items;"
          expect(buffer.lineForRow(3)).toBe "    var pivot = sort(Array.apply(this, arguments));"
          expect(buffer.lineForRow(4)).toBe "};"

    describe "when used to replace text with other text (called with non-empty range and non-empty string)", ->
      it "replaces the old text with the new text", ->
        range = [[3, 16], [11, 9]]
        oldText = buffer.getTextInRange(range)

        buffer.setTextInRange range, "foo\nbar"

        expect(buffer.lineForRow(2)).toBe "    if (items.length <= 1) return items;"
        expect(buffer.lineForRow(3)).toBe "    var pivot = foo"
        expect(buffer.lineForRow(4)).toBe "barsort(Array.apply(this, arguments));"
        expect(buffer.lineForRow(5)).toBe "};"

        expect(changeHandler).toHaveBeenCalled()
        [event] = changeHandler.calls.allArgs()[0]
        expect(event.oldRange).toEqual range
        expect(event.newRange).toEqual [[3, 16], [4, 3]]
        expect(event.oldText).toBe oldText
        expect(event.newText).toBe "foo\nbar"

    it "allows a change to be undone safely from an ::onDidChange callback", ->
      buffer.onDidChange -> buffer.undo()
      buffer.setTextInRange([[0, 0], [0, 0]], "hello")
      expect(buffer.lineForRow(0)).toBe "var quicksort = function () {"

  describe "::setText(text)", ->
    beforeEach ->
      filePath = require.resolve('./fixtures/sample.js')
      fileContents = fs.readFileSync(filePath, 'utf8')
      buffer = new TextBuffer(filePath)

    describe "when the buffer contains newlines", ->
      it "changes the entire contents of the buffer and emits a change event", ->
        lastRow = buffer.getLastRow()
        expectedPreRange = [[0,0], [lastRow, buffer.lineForRow(lastRow).length]]
        changeHandler = jasmine.createSpy('changeHandler')
        buffer.onDidChange changeHandler

        newText = "I know you are.\rBut what am I?"
        buffer.setText(newText)

        expect(buffer.getText()).toBe newText
        expect(changeHandler).toHaveBeenCalled()

        [event] = changeHandler.calls.allArgs()[0]
        expect(event.newText).toBe newText
        expect(event.oldRange).toEqual expectedPreRange
        expect(event.newRange).toEqual [[0, 0], [1, 14]]

    describe "with windows newlines", ->
      it "changes the entire contents of the buffer", ->
        buffer = new TextBuffer("first\r\nlast")
        lastRow = buffer.getLastRow()
        expectedPreRange = [[0,0], [lastRow, buffer.lineForRow(lastRow).length]]
        changeHandler = jasmine.createSpy('changeHandler')
        buffer.onDidChange changeHandler

        newText = "new first\r\nnew last"
        buffer.setText(newText)

        expect(buffer.getText()).toBe newText
        expect(changeHandler).toHaveBeenCalled()

        [event] = changeHandler.calls.allArgs()[0]
        expect(event.newText).toBe newText
        expect(event.oldRange).toEqual expectedPreRange
        expect(event.newRange).toEqual [[0, 0], [1, 8]]

    describe "when the buffer contains carriage returns for newlines", ->
      it "changes the entire contents of the buffer", ->
        buffer = new TextBuffer("first\rlast")
        lastRow = buffer.getLastRow()
        expectedPreRange = [[0,0], [lastRow, buffer.lineForRow(lastRow).length]]
        changeHandler = jasmine.createSpy('changeHandler')
        buffer.onDidChange changeHandler

        newText = "new first\rnew last"
        buffer.setText(newText)

        expect(buffer.getText()).toBe newText
        expect(changeHandler).toHaveBeenCalled()
        [event] = changeHandler.calls.allArgs()[0]
        expect(event.newText).toBe newText
        expect(event.oldRange).toEqual expectedPreRange
        expect(event.newRange).toEqual [[0, 0], [1, 8]]

  describe "::setTextViaDiff(text)", ->
    beforeEach ->
      filePath = require.resolve('./fixtures/sample.js')
      fileContents = fs.readFileSync(filePath, 'utf8')
      buffer = new TextBuffer(fileContents)

    it "can change the entire contents of the buffer when there are no newlines", ->
      buffer.setText('BUFFER CHANGE')
      newText = 'DISK CHANGE'
      buffer.setTextViaDiff(newText)
      expect(buffer.getText()).toBe newText

    describe "with standard newlines", ->
      it "can change the entire contents of the buffer with no newline at the end", ->
        newText = "I know you are.\nBut what am I?"
        buffer.setTextViaDiff(newText)
        expect(buffer.getText()).toBe newText

      it "can change the entire contents of the buffer with a newline at the end", ->
        newText = "I know you are.\nBut what am I?\n"
        buffer.setTextViaDiff(newText)
        expect(buffer.getText()).toBe newText

      it "can change a few lines at the beginning in the buffer", ->
        newText = buffer.getText().replace(/function/g, 'omgwow')
        buffer.setTextViaDiff(newText)
        expect(buffer.getText()).toBe newText

      it "can change a few lines in the middle of the buffer", ->
        newText = buffer.getText().replace(/shift/g, 'omgwow')
        buffer.setTextViaDiff(newText)
        expect(buffer.getText()).toBe newText

      it "can adds a newline at the end", ->
        newText = buffer.getText() + '\n'
        buffer.setTextViaDiff(newText)
        expect(buffer.getText()).toBe newText

    describe "with windows newlines", ->
      beforeEach ->
        buffer.setText(buffer.getText().replace(/\n/g, '\r\n'))

      it "adds a newline at the end", ->
        newText = buffer.getText() + '\r\n'
        buffer.setTextViaDiff(newText)
        expect(buffer.getText()).toBe newText

      it "changes the entire contents of the buffer with smaller content with no newline at the end", ->
        newText = "I know you are.\r\nBut what am I?"
        buffer.setTextViaDiff(newText)
        expect(buffer.getText()).toBe newText

      it "changes the entire contents of the buffer with smaller content with newline at the end", ->
        newText = "I know you are.\r\nBut what am I?\r\n"
        buffer.setTextViaDiff(newText)
        expect(buffer.getText()).toBe newText

      it "changes a few lines at the beginning in the buffer", ->
        newText = buffer.getText().replace(/function/g, 'omgwow')
        buffer.setTextViaDiff(newText)
        expect(buffer.getText()).toBe newText

      it "changes a few lines in the middle of the buffer", ->
        newText = buffer.getText().replace(/shift/g, 'omgwow')
        buffer.setTextViaDiff(newText)
        expect(buffer.getText()).toBe newText

    describe "when the buffer contains carriage returns for newlines", ->
      it "can replace the contents of the buffer", ->
        originalText = "beginning\rmiddle\rlast"
        newText = "new beginning\rnew last"
        buffer = new TextBuffer(originalText)
        expect(buffer.getText()).toBe originalText

        buffer.setTextViaDiff(newText)
        expect(buffer.getText()).toBe newText

        buffer.setTextViaDiff(originalText)
        expect(buffer.getText()).toBe originalText

  describe "::getTextInRange(range)", ->
    beforeEach ->
      filePath = require.resolve('./fixtures/sample.js')
      fileContents = fs.readFileSync(filePath, 'utf8')
      buffer = new TextBuffer(fileContents)

    describe "when range is empty", ->
      it "returns an empty string", ->
        range = [[1,1], [1,1]]
        expect(buffer.getTextInRange(range)).toBe ""

    describe "when range spans one line", ->
      it "returns characters in range", ->
        range = [[2,8], [2,13]]
        expect(buffer.getTextInRange(range)).toBe "items"

        lineLength = buffer.lineForRow(2).length
        range = [[2,0], [2,lineLength]]
        expect(buffer.getTextInRange(range)).toBe "    if (items.length <= 1) return items;"

    describe "when range spans multiple lines", ->
      it "returns characters in range (including newlines)", ->
        lineLength = buffer.lineForRow(2).length
        range = [[2,0], [3,0]]
        expect(buffer.getTextInRange(range)).toBe "    if (items.length <= 1) return items;\n"

        lineLength = buffer.lineForRow(2).length
        range = [[2,10], [4,10]]
        expect(buffer.getTextInRange(range)).toBe "ems.length <= 1) return items;\n    var pivot = items.shift(), current, left = [], right = [];\n    while("

    describe "when the range starts before the start of the buffer", ->
      it "clips the range to the start of the buffer", ->
        expect(buffer.getTextInRange([[-Infinity, -Infinity], [0, Infinity]])).toBe buffer.lineForRow(0)

    describe "when the range ends after the end of the buffer", ->
      it "clips the range to the end of the buffer", ->
        expect(buffer.getTextInRange([[12], [13, Infinity]])).toBe buffer.lineForRow(12)

  describe "::scan(regex, fn)", ->
    beforeEach ->
      filePath = require.resolve('./fixtures/sample.js')
      fileContents = fs.readFileSync(filePath, 'utf8')
      buffer = new TextBuffer(fileContents)

    it "calls the given function with the information about each match", ->
      matches = []
      buffer.scan /current/g, (match) -> matches.push(match)
      expect(matches.length).toBe 5

      expect(matches[0].matchText).toBe 'current'
      expect(matches[0].range).toEqual [[3, 31], [3, 38]]
      expect(matches[0].lineText).toBe '    var pivot = items.shift(), current, left = [], right = [];'
      expect(matches[0].lineTextOffset).toBe 0

      expect(matches[1].matchText).toBe 'current'
      expect(matches[1].range).toEqual [[5, 6], [5, 13]]
      expect(matches[1].lineText).toBe '      current = items.shift();'
      expect(matches[1].lineTextOffset).toBe 0

  describe "::backwardsScan(regex, fn)", ->
    beforeEach ->
      filePath = require.resolve('./fixtures/sample.js')
      fileContents = fs.readFileSync(filePath, 'utf8')
      buffer = new TextBuffer(fileContents)

    it "calls the given function with the information about each match in backwards order", ->
      matches = []
      buffer.backwardsScan /current/g, (match) -> matches.push(match)
      expect(matches.length).toBe 5

      expect(matches[0].matchText).toBe 'current'
      expect(matches[0].range).toEqual [[6, 56], [6, 63]]
      expect(matches[0].lineText).toBe '      current < pivot ? left.push(current) : right.push(current);'
      expect(matches[0].lineTextOffset).toBe 0

      expect(matches[1].matchText).toBe 'current'
      expect(matches[1].range).toEqual [[6, 34], [6, 41]]
      expect(matches[1].lineText).toBe '      current < pivot ? left.push(current) : right.push(current);'
      expect(matches[1].lineTextOffset).toBe 0

  describe "::scanInRange(range, regex, fn)", ->
    beforeEach ->
      filePath = require.resolve('./fixtures/sample.js')
      fileContents = fs.readFileSync(filePath, 'utf8')
      buffer = new TextBuffer(fileContents)

    describe "when given a regex with a ignore case flag", ->
      it "does a case-insensitive search", ->
        matches = []
        buffer.scanInRange /cuRRent/i, [[0,0], [12,0]], ({match, range}) ->
          matches.push(match)
        expect(matches.length).toBe 1

    describe "when given a regex with no global flag", ->
      it "calls the iterator with the first match for the given regex in the given range", ->
        matches = []
        ranges = []
        buffer.scanInRange /cu(rr)ent/, [[4,0], [6,44]], ({match, range}) ->
          matches.push(match)
          ranges.push(range)

        expect(matches.length).toBe 1
        expect(ranges.length).toBe 1

        expect(matches[0][0]).toBe 'current'
        expect(matches[0][1]).toBe 'rr'
        expect(ranges[0]).toEqual [[5,6], [5,13]]

    describe "when given a regex with a global flag", ->
      it "calls the iterator with each match for the given regex in the given range", ->
        matches = []
        ranges = []
        buffer.scanInRange /cu(rr)ent/g, [[4,0], [6,59]], ({match, range}) ->
          matches.push(match)
          ranges.push(range)

        expect(matches.length).toBe 3
        expect(ranges.length).toBe 3

        expect(matches[0][0]).toBe 'current'
        expect(matches[0][1]).toBe 'rr'
        expect(ranges[0]).toEqual [[5,6], [5,13]]

        expect(matches[1][0]).toBe 'current'
        expect(matches[1][1]).toBe 'rr'
        expect(ranges[1]).toEqual [[6,6], [6,13]]

        expect(matches[2][0]).toBe 'current'
        expect(matches[2][1]).toBe 'rr'
        expect(ranges[2]).toEqual [[6,34], [6,41]]

    describe "when the last regex match exceeds the end of the range", ->
      describe "when the portion of the match within the range also matches the regex", ->
        it "calls the iterator with the truncated match", ->
          matches = []
          ranges = []
          buffer.scanInRange /cu(r*)/g, [[4,0], [6,9]], ({match, range}) ->
            matches.push(match)
            ranges.push(range)

          expect(matches.length).toBe 2
          expect(ranges.length).toBe 2

          expect(matches[0][0]).toBe 'curr'
          expect(matches[0][1]).toBe 'rr'
          expect(ranges[0]).toEqual [[5,6], [5,10]]

          expect(matches[1][0]).toBe 'cur'
          expect(matches[1][1]).toBe 'r'
          expect(ranges[1]).toEqual [[6,6], [6,9]]

      describe "when the portion of the match within the range does not matches the regex", ->
        it "does not call the iterator with the truncated match", ->
          matches = []
          ranges = []
          buffer.scanInRange /cu(r*)e/g, [[4,0], [6,9]], ({match, range}) ->
            matches.push(match)
            ranges.push(range)

          expect(matches.length).toBe 1
          expect(ranges.length).toBe 1

          expect(matches[0][0]).toBe 'curre'
          expect(matches[0][1]).toBe 'rr'
          expect(ranges[0]).toEqual [[5,6], [5,11]]

    describe "when the iterator calls the 'replace' control function with a replacement string", ->
      it "replaces each occurrence of the regex match with the string", ->
        ranges = []
        buffer.scanInRange /cu(rr)ent/g, [[4,0], [6,59]], ({range, replace}) ->
          ranges.push(range)
          replace("foo")

        expect(ranges[0]).toEqual [[5,6], [5,13]]
        expect(ranges[1]).toEqual [[6,6], [6,13]]
        expect(ranges[2]).toEqual [[6,30], [6,37]]

        expect(buffer.lineForRow(5)).toBe '      foo = items.shift();'
        expect(buffer.lineForRow(6)).toBe '      foo < pivot ? left.push(foo) : right.push(current);'

      it "allows the match to be replaced with the empty string", ->
        buffer.scanInRange /current/g, [[4,0], [6,59]], ({replace}) ->
          replace("")

        expect(buffer.lineForRow(5)).toBe '       = items.shift();'
        expect(buffer.lineForRow(6)).toBe '       < pivot ? left.push() : right.push(current);'

    describe "when the iterator calls the 'stop' control function", ->
      it "stops the traversal", ->
        ranges = []
        buffer.scanInRange /cu(rr)ent/g, [[4,0], [6,59]], ({range, stop}) ->
          ranges.push(range)
          stop() if ranges.length == 2

        expect(ranges.length).toBe 2

  describe "::backwardsScanInRange(range, regex, fn)", ->
    beforeEach ->
      filePath = require.resolve('./fixtures/sample.js')
      fileContents = fs.readFileSync(filePath, 'utf8')
      buffer = new TextBuffer(fileContents)

    describe "when given a regex with no global flag", ->
      it "calls the iterator with the last match for the given regex in the given range", ->
        matches = []
        ranges = []
        buffer.backwardsScanInRange /cu(rr)ent/, [[4,0], [6,44]], ({match, range}) ->
          matches.push(match)
          ranges.push(range)

        expect(matches.length).toBe 1
        expect(ranges.length).toBe 1

        expect(matches[0][0]).toBe 'current'
        expect(matches[0][1]).toBe 'rr'
        expect(ranges[0]).toEqual [[6,34], [6,41]]

    describe "when given a regex with a global flag", ->
      it "calls the iterator with each match for the given regex in the given range, starting with the last match", ->
        matches = []
        ranges = []
        buffer.backwardsScanInRange /cu(rr)ent/g, [[4,0], [6,59]], ({match, range}) ->
          matches.push(match)
          ranges.push(range)

        expect(matches.length).toBe 3
        expect(ranges.length).toBe 3

        expect(matches[0][0]).toBe 'current'
        expect(matches[0][1]).toBe 'rr'
        expect(ranges[0]).toEqual [[6,34], [6,41]]

        expect(matches[1][0]).toBe 'current'
        expect(matches[1][1]).toBe 'rr'
        expect(ranges[1]).toEqual [[6,6], [6,13]]

        expect(matches[2][0]).toBe 'current'
        expect(matches[2][1]).toBe 'rr'
        expect(ranges[2]).toEqual [[5,6], [5,13]]

    describe "when the last regex match starts at the beginning of the range", ->
      it "calls the iterator with the match", ->
        matches = []
        ranges = []
        buffer.scanInRange /quick/g, [[0,4], [2,0]], ({match, range}) ->
          matches.push(match)
          ranges.push(range)

        expect(matches.length).toBe 1
        expect(ranges.length).toBe 1

        expect(matches[0][0]).toBe 'quick'
        expect(ranges[0]).toEqual [[0,4], [0,9]]

        matches = []
        ranges = []
        buffer.scanInRange /^/, [[0,0], [2,0]], ({match, range}) ->
          matches.push(match)
          ranges.push(range)

        expect(matches.length).toBe 1
        expect(ranges.length).toBe 1

        expect(matches[0][0]).toBe ""
        expect(ranges[0]).toEqual [[0,0], [0,0]]

    describe "when the first regex match exceeds the end of the range", ->
      describe "when the portion of the match within the range also matches the regex", ->
        it "calls the iterator with the truncated match", ->
          matches = []
          ranges = []
          buffer.backwardsScanInRange /cu(r*)/g, [[4,0], [6,9]], ({match, range}) ->
            matches.push(match)
            ranges.push(range)

          expect(matches.length).toBe 2
          expect(ranges.length).toBe 2

          expect(matches[0][0]).toBe 'cur'
          expect(matches[0][1]).toBe 'r'
          expect(ranges[0]).toEqual [[6,6], [6,9]]

          expect(matches[1][0]).toBe 'curr'
          expect(matches[1][1]).toBe 'rr'
          expect(ranges[1]).toEqual [[5,6], [5,10]]

      describe "when the portion of the match within the range does not matches the regex", ->
        it "does not call the iterator with the truncated match", ->
          matches = []
          ranges = []
          buffer.backwardsScanInRange /cu(r*)e/g, [[4,0], [6,9]], ({match, range}) ->
            matches.push(match)
            ranges.push(range)

          expect(matches.length).toBe 1
          expect(ranges.length).toBe 1

          expect(matches[0][0]).toBe 'curre'
          expect(matches[0][1]).toBe 'rr'
          expect(ranges[0]).toEqual [[5,6], [5,11]]

    describe "when the iterator calls the 'replace' control function with a replacement string", ->
      it "replaces each occurrence of the regex match with the string", ->
        ranges = []
        buffer.backwardsScanInRange /cu(rr)ent/g, [[4,0], [6,59]], ({range, replace}) ->
          ranges.push(range)
          replace("foo") unless range.start.isEqual([6,6])

        expect(ranges[0]).toEqual [[6,34], [6,41]]
        expect(ranges[1]).toEqual [[6,6], [6,13]]
        expect(ranges[2]).toEqual [[5,6], [5,13]]

        expect(buffer.lineForRow(5)).toBe '      foo = items.shift();'
        expect(buffer.lineForRow(6)).toBe '      current < pivot ? left.push(foo) : right.push(current);'

    describe "when the iterator calls the 'stop' control function", ->
      it "stops the traversal", ->
        ranges = []
        buffer.backwardsScanInRange /cu(rr)ent/g, [[4,0], [6,59]], ({range, stop}) ->
          ranges.push(range)
          stop() if ranges.length == 2

        expect(ranges.length).toBe 2
        expect(ranges[0]).toEqual [[6,34], [6,41]]
        expect(ranges[1]).toEqual [[6,6], [6,13]]

    describe "when called with a random range", ->
      it "returns the same results as ::scanInRange, but in the opposite order", ->
        for i in [1...50]
          seed = Date.now()
          random = new Random(seed)

          buffer.backwardsScanChunkSize = random.intBetween(1, 80)

          [startRow, endRow] = [random(buffer.getLineCount()), random(buffer.getLineCount())].sort()
          startColumn = random(buffer.lineForRow(startRow).length)
          endColumn = random(buffer.lineForRow(endRow).length)
          range = [[startRow, startColumn], [endRow, endColumn]]

          regex = [
            /\w/g
            /\w{2}/g
            /\w{3}/g
            /.{5}/g
          ][random(4)]

          if random(2) > 0
            forwardRanges = []
            backwardRanges = []
            forwardMatches = []
            backwardMatches = []

            buffer.scanInRange regex, range, ({range, matchText}) ->
              forwardMatches.push(matchText)
              forwardRanges.push(range)

            buffer.backwardsScanInRange regex, range, ({range, matchText}) ->
              backwardMatches.unshift(matchText)
              backwardRanges.unshift(range)

            expect(backwardRanges).toEqual(forwardRanges, "Seed: #{seed}")
            expect(backwardMatches).toEqual(forwardMatches, "Seed: #{seed}")
          else
            referenceBuffer = new TextBuffer(text: buffer.getText())
            referenceBuffer.scanInRange regex, range, ({matchText, replace}) ->
              replace(matchText + '.')

            buffer.backwardsScanInRange regex, range, ({matchText, replace}) ->
              replace(matchText + '.')

            expect(buffer.getText()).toBe(referenceBuffer.getText(), "Seed: #{seed}")

  describe "::characterIndexForPosition(position)", ->
    beforeEach ->
      filePath = require.resolve('./fixtures/sample.js')
      fileContents = fs.readFileSync(filePath, 'utf8')
      buffer = new TextBuffer(fileContents)

    it "returns the total number of characters that precede the given position", ->
      expect(buffer.characterIndexForPosition([0, 0])).toBe 0
      expect(buffer.characterIndexForPosition([0, 1])).toBe 1
      expect(buffer.characterIndexForPosition([0, 29])).toBe 29
      expect(buffer.characterIndexForPosition([1, 0])).toBe 30
      expect(buffer.characterIndexForPosition([2, 0])).toBe 61
      expect(buffer.characterIndexForPosition([12, 2])).toBe 408
      expect(buffer.characterIndexForPosition([Infinity])).toBe 408

    describe "when the buffer contains crlf line endings", ->
      it "returns the total number of characters that precede the given position", ->
        buffer.setText("line1\r\nline2\nline3\r\nline4")
        expect(buffer.characterIndexForPosition([1])).toBe 7
        expect(buffer.characterIndexForPosition([2])).toBe 13
        expect(buffer.characterIndexForPosition([3])).toBe 20

  describe "::positionForCharacterIndex(position)", ->
    beforeEach ->
      filePath = require.resolve('./fixtures/sample.js')
      fileContents = fs.readFileSync(filePath, 'utf8')
      buffer = new TextBuffer(fileContents)

    it "returns the position based on character index", ->
      expect(buffer.positionForCharacterIndex(0)).toEqual [0, 0]
      expect(buffer.positionForCharacterIndex(1)).toEqual [0, 1]
      expect(buffer.positionForCharacterIndex(29)).toEqual [0, 29]
      expect(buffer.positionForCharacterIndex(30)).toEqual [1, 0]
      expect(buffer.positionForCharacterIndex(61)).toEqual [2, 0]
      expect(buffer.positionForCharacterIndex(408)).toEqual [12, 2]

    describe "when the buffer contains crlf line endings", ->
      it "returns the position based on character index", ->
        buffer.setText("line1\r\nline2\nline3\r\nline4")
        expect(buffer.positionForCharacterIndex(7)).toEqual [1, 0]
        expect(buffer.positionForCharacterIndex(13)).toEqual [2, 0]
        expect(buffer.positionForCharacterIndex(20)).toEqual [3, 0]

  describe "::isEmpty()", ->
    beforeEach ->
      filePath = require.resolve('./fixtures/sample.js')
      fileContents = fs.readFileSync(filePath, 'utf8')
      buffer = new TextBuffer(fileContents)

    it "returns true for an empty buffer", ->
      buffer.setText('')
      expect(buffer.isEmpty()).toBeTruthy()

    it "returns false for a non-empty buffer", ->
      buffer.setText('a')
      expect(buffer.isEmpty()).toBeFalsy()
      buffer.setText('a\nb\nc')
      expect(buffer.isEmpty()).toBeFalsy()
      buffer.setText('\n')
      expect(buffer.isEmpty()).toBeFalsy()

  describe "::onDidChangeText(callback)",  ->
    beforeEach ->
      filePath = require.resolve('./fixtures/sample.js')
      fileContents = fs.readFileSync(filePath, 'utf8')
      buffer = new TextBuffer(fileContents)

    it "notifies observers after a transaction, an undo or a redo", ->
      textChanges = []
      buffer.onDidChangeText ({changes}) -> textChanges.push(changes...)

      buffer.insert([0, 0], "abc")
      buffer.delete([[0, 0], [0, 1]])
      expect(textChanges).toEqual([
        {
          start: {row: 0, column: 0},
          oldExtent: {row: 0, column: 0},
          newExtent: {row: 0, column: 3},
          newText: "abc"
        },
        {
          start: {row: 0, column: 0},
          oldExtent: {row: 0, column: 1},
          newExtent: {row: 0, column: 0},
          newText: ""
        }
      ])

      textChanges = []
      buffer.transact ->
        buffer.insert([1, 0], "x")
        buffer.insert([1, 1], "y")
        buffer.insert([2, 3], "zw")
        buffer.delete([[2, 3], [2, 4]])

      expect(textChanges).toEqual([
        {
          start: {row: 1, column: 0},
          oldExtent: {row: 0, column: 0},
          newExtent: {row: 0, column: 2},
          newText: "xy"
        },
        {
          start: {row: 2, column: 3},
          oldExtent: {row: 0, column: 0},
          newExtent: {row: 0, column: 1},
          newText: "w"
        }
      ])

      textChanges = []
      buffer.undo()
      expect(textChanges).toEqual([
        {
          start: {row: 1, column: 0},
          oldExtent: {row: 0, column: 2},
          newExtent: {row: 0, column: 0},
          newText: ""
        },
        {
          start: {row: 2, column: 3},
          oldExtent: {row: 0, column: 1},
          newExtent: {row: 0, column: 0},
          newText: ""
        }
      ])

      textChanges = []
      buffer.redo()
      expect(textChanges).toEqual([
        {
          start: {row: 1, column: 0},
          oldExtent: {row: 0, column: 0},
          newExtent: {row: 0, column: 2},
          newText: "xy"
        },
        {
          start: {row: 2, column: 3},
          oldExtent: {row: 0, column: 0},
          newExtent: {row: 0, column: 1},
          newText: "w"
        }
      ])

      textChanges = []
      buffer.transact ->
        buffer.transact ->
          buffer.insert([0, 0], "j")

      # we emit only one event for nested transactions
      expect(textChanges).toEqual([
        {
          start: {row: 0, column: 0},
          oldExtent: {row: 0, column: 0},
          newExtent: {row: 0, column: 1},
          newText: "j"
        }
      ])

    it "doesn't throw an error when clearing the undo stack within a transaction", ->
      buffer.onDidChangeText(didChangeTextSpy = jasmine.createSpy())
      expect(-> buffer.transact(-> buffer.clearUndoStack())).not.toThrowError()
      expect(didChangeTextSpy).not.toHaveBeenCalled()

  describe "::onDidStopChanging(callback)", ->
    [delay, didStopChangingCallback] = []
    beforeEach ->
      filePath = require.resolve('./fixtures/sample.js')
      fileContents = fs.readFileSync(filePath, 'utf8')
      buffer = new TextBuffer(fileContents)

    beforeEach (done) ->
      delay = buffer.stoppedChangingDelay
      didStopChangingCallback = jasmine.createSpy("didStopChangingCallback")
      setTimeout(->
        done()
      , delay)

    beforeEach (done) ->
      buffer.onDidStopChanging didStopChangingCallback

      buffer.insert([0, 0], 'a')
      expect(didStopChangingCallback).not.toHaveBeenCalled()
      setTimeout(->
        done()
      , delay / 2)

    beforeEach (done) ->
      buffer.transact ->
        buffer.transact ->
          buffer.insert([0, 0], 'b')
          buffer.insert([1, 0], 'c')
      expect(didStopChangingCallback).not.toHaveBeenCalled()
      setTimeout(->
        done()
      , delay / 2)

    beforeEach (done) ->
      expect(didStopChangingCallback).not.toHaveBeenCalled()
      setTimeout(->
        done()
      , delay / 2)

    beforeEach (done) ->
      expect(didStopChangingCallback).toHaveBeenCalled()
      expect(didStopChangingCallback.calls.mostRecent().args[0].changes).toEqual [
        {
          start: {row: 0, column: 0},
          oldExtent: {row: 0, column: 0},
          newExtent: {row: 0, column: 2},
          newText: 'ba'
        },
        {
          start: {row: 1, column: 0},
          oldExtent: {row: 0, column: 0},
          newExtent: {row: 0, column: 1},
          newText: 'c'
        }
      ]

      didStopChangingCallback.calls.reset()
      buffer.undo()
      buffer.undo()
      setTimeout(->
        done()
      , delay)

    it "notifies observers after a delay passes following changes", ->
        expect(didStopChangingCallback).toHaveBeenCalled()

  describe "::append(text)", ->
    beforeEach ->
      filePath = require.resolve('./fixtures/sample.js')
      fileContents = fs.readFileSync(filePath, 'utf8')
      buffer = new TextBuffer(fileContents)

    it "adds text to the end of the buffer", ->
      buffer.setText("")
      buffer.append("a")
      expect(buffer.getText()).toBe "a"
      buffer.append("b\nc")
      expect(buffer.getText()).toBe "ab\nc"

  describe "line ending support", ->
    beforeEach ->
      filePath = require.resolve('./fixtures/sample.js')
      fileContents = fs.readFileSync(filePath, 'utf8')
      buffer = new TextBuffer(fileContents)

    describe ".getText()", ->
      it "returns the text with the corrent line endings for each row", ->
        buffer.setText("a\r\nb\nc")
        expect(buffer.getText()).toBe "a\r\nb\nc"
        buffer.setText("a\r\nb\nc\n")
        expect(buffer.getText()).toBe "a\r\nb\nc\n"

    describe "when editing a line", ->
      it "preserves the existing line ending", ->
        buffer.setText("a\r\nb\nc")
        buffer.insert([0, 1], "1")
        expect(buffer.getText()).toBe "a1\r\nb\nc"

    describe "when inserting text with multiple lines", ->
      describe "when the current line has a line ending", ->
        it "uses the same line ending as the line where the text is inserted", ->
          buffer.setText("a\r\n")
          buffer.insert([0, 1], "hello\n1\n\n2")
          expect(buffer.getText()).toBe "ahello\r\n1\r\n\r\n2\r\n"

      describe "when the current line has no line ending (because it's the last line of the buffer)", ->
        describe "when the buffer contains only a single line", ->
          it "honors the line endings in the inserted text", ->
            buffer.setText("initialtext")
            buffer.append("hello\n1\r\n2\n")
            expect(buffer.getText()).toBe "initialtexthello\n1\r\n2\n"

        describe "when the buffer contains a preceding line", ->
          it "uses the line ending of the preceding line", ->
            buffer.setText("\ninitialtext")
            buffer.append("hello\n1\r\n2\n")
            expect(buffer.getText()).toBe "\ninitialtexthello\n1\n2\n"

    describe "::setPreferredLineEnding(lineEnding)", ->
      it "uses the given line ending when normalizing, rather than inferring one from the surrounding text", ->
        buffer = new TextBuffer(text: "a \r\n")

        expect(buffer.getPreferredLineEnding()).toBe null
        buffer.append(" b \n")
        expect(buffer.getText()).toBe "a \r\n b \r\n"

        buffer.setPreferredLineEnding("\n")
        expect(buffer.getPreferredLineEnding()).toBe "\n"
        buffer.append(" c \n")
        expect(buffer.getText()).toBe "a \r\n b \r\n c \n"

        buffer.setPreferredLineEnding(null)
        buffer.append(" d \r\n")
        expect(buffer.getText()).toBe "a \r\n b \r\n c \n d \n"

      it "persists across serialization and deserialization", ->
        bufferA = new TextBuffer
        bufferA.setPreferredLineEnding("\r\n")

        bufferB = TextBuffer.deserialize(bufferA.serialize())
        expect(bufferB.getPreferredLineEnding()).toBe "\r\n"

  describe "character set encoding support", ->
    it "allows the encoding to be set on creation", ->
      filePath = join(__dirname, 'fixtures', 'win1251.txt')
      fileContents = iconv.decode(fs.readFileSync(filePath), 'win1251')
      buffer = new TextBuffer({encoding: 'win1251'})
      buffer.setText(fileContents)
      expect(buffer.getEncoding()).toBe 'win1251'
      expect(buffer.getText()).toBe 'тест 1234 абвгдеёжз'

    it "serializes the encoding", ->
      filePath = join(__dirname, 'fixtures', 'win1251.txt')
      fileContents = iconv.decode(fs.readFileSync(filePath), 'win1251')
      bufferA = new TextBuffer({encoding: 'win1251'})
      bufferA.setText(fileContents)
      bufferB = TextBuffer.deserialize(bufferA.serialize())
      expect(bufferB.getEncoding()).toBe 'win1251'
      expect(bufferB.getText()).toBe 'тест 1234 абвгдеёжз'

    it "emits an event when the encoding changes", ->
      filePath = join(__dirname, 'fixtures', 'win1251.txt')
      fileContents = iconv.decode(fs.readFileSync(filePath), 'win1251')
      encodingChangeHandler = jasmine.createSpy('encodingChangeHandler')

      buffer = new TextBuffer(fileContents)
      buffer.onDidChangeEncoding(encodingChangeHandler)
      buffer.setEncoding('win1251')
      expect(encodingChangeHandler).toHaveBeenCalledWith('win1251')

      encodingChangeHandler.calls.reset()
      buffer.setEncoding('win1251')
      expect(encodingChangeHandler.calls.count()).toBe 0

      encodingChangeHandler.calls.reset()

      buffer = new TextBuffer()
      buffer.onDidChangeEncoding(encodingChangeHandler)
      buffer.setEncoding('win1251')
      expect(encodingChangeHandler).toHaveBeenCalledWith('win1251')

      encodingChangeHandler.calls.reset()
      buffer.setEncoding('win1251')
      expect(encodingChangeHandler.calls.count()).toBe 0
