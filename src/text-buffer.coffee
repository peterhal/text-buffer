{Emitter, CompositeDisposable} = require 'event-kit'
SpanSkipList = require 'span-skip-list'
diff = require 'diff'
_ = require 'underscore-plus'
crypto = require 'crypto'
Patch = require 'atom-patch'
Point = require './point'
Range = require './range'
History = require './history'
MatchIterator = require './match-iterator'
{spliceArray, newlineRegex, normalizePatchChanges} = require './helpers'

class SearchCallbackArgument
  Object.defineProperty @::, "range",
    get: ->
      return @computedRange if @computedRange?

      matchStartIndex = @match.index
      matchEndIndex = matchStartIndex + @matchText.length

      startPosition = @buffer.positionForCharacterIndex(matchStartIndex + @lengthDelta)
      endPosition = @buffer.positionForCharacterIndex(matchEndIndex + @lengthDelta)

      @computedRange = new Range(startPosition, endPosition)

    set: (range) ->
      @computedRange = range

  constructor: (@buffer, @match, @lengthDelta) ->
    @stopped = false
    @replacementText = null
    @matchText = @match[0]

  getReplacementDelta: ->
    return 0 unless @replacementText?

    @replacementText.length - @matchText.length

  replace: (text) =>
    @replacementText = text
    @buffer.setTextInRange(@range, @replacementText)

  stop: =>
    @stopped = true

  keepLooping: ->
    @stopped is false

class TransactionAbortedError extends Error
  constructor: -> super

# Extended: A mutable text container with undo/redo support and the ability to
# annotate logical regions in the text.
module.exports =
class TextBuffer
  @version: 5
  @Point: Point
  @Range: Range
  @Patch: require('./patch')
  @newlineRegex: newlineRegex

  cachedText: null
  encoding: null
  stoppedChangingDelay: 300
  stoppedChangingTimeout: null
  refcount: 0
  backwardsScanChunkSize: 8000
  defaultMaxUndoEntries: 10000
  changeCount: 0

  ###
  Section: Construction
  ###

  # Public: Create a new buffer with the given params.
  #
  # * `params` {Object} or {String} of text
  #   * `text` The initial {String} text of the buffer.
  constructor: (params) ->
    text = params if typeof params is 'string'

    @emitter = new Emitter
    @patchesSinceLastStoppedChangingEvent = []
    @didChangeTextPatch = new Patch
    @id = params?.id ? crypto.randomBytes(16).toString('hex')
    @lines = ['']
    @lineEndings = ['']
    @offsetIndex = new SpanSkipList('rows', 'characters')
    @setTextInRange([[0, 0], [0, 0]], text ? params?.text ? '', normalizeLineEndings: false)
    maxUndoEntries = params?.maxUndoEntries ? @defaultMaxUndoEntries
    @history = params?.history ? new History(this, maxUndoEntries)

    @setEncoding(params?.encoding)
    @setPreferredLineEnding(params?.preferredLineEnding)

    @transactCallDepth = 0

  @deserialize: (params) ->
    return if params.version isnt TextBuffer.prototype.version

    buffer = Object.create(TextBuffer.prototype)
    params.history = History.deserialize(params.history, buffer)
    TextBuffer.call(buffer, params)
    buffer

  # Returns a {String} representing a unique identifier for this {TextBuffer}.
  getId: ->
    @id

  serialize: (options) ->
    options ?= {}

    id: @getId()
    text: @getText()
    history: @history.serialize(options)
    encoding: @getEncoding()
    preferredLineEnding: @preferredLineEnding

  ###
  Section: Event Subscription
  ###

  # Public: Invoke the given callback synchronously _before_ the content of the
  # buffer changes.
  #
  # Because observers are invoked synchronously, it's important not to perform
  # any expensive operations via this method.
  #
  # * `callback` {Function} to be called when the buffer changes.
  #   * `event` {Object} with the following keys:
  #     * `oldRange` {Range} of the old text.
  #     * `newRange` {Range} of the new text.
  #     * `oldText` {String} containing the text that was replaced.
  #     * `newText` {String} containing the text that was inserted.
  #
  # Returns a {Disposable} on which `.dispose()` can be called to unsubscribe.
  onWillChange: (callback) ->
    @emitter.on 'will-change', callback

  # Public: Invoke the given callback synchronously when the content of the
  # buffer changes.
  #
  # Because observers are invoked synchronously, it's important not to perform
  # any expensive operations via this method. Consider {::onDidStopChanging} to
  # delay expensive operations until after changes stop occurring.
  #
  # * `callback` {Function} to be called when the buffer changes.
  #   * `event` {Object} with the following keys:
  #     * `oldRange` {Range} of the old text.
  #     * `newRange` {Range} of the new text.
  #     * `oldText` {String} containing the text that was replaced.
  #     * `newText` {String} containing the text that was inserted.
  #
  # Returns a {Disposable} on which `.dispose()` can be called to unsubscribe.
  onDidChange: (callback) ->
    @emitter.on 'did-change', callback

  onDidChangeText: (callback) ->
    @emitter.on 'did-change-text', callback

  preemptDidChange: (callback) ->
    @emitter.preempt 'did-change', callback

  # Public: Invoke the given callback asynchronously following one or more
  # changes after {::getStoppedChangingDelay} milliseconds elapse without an
  # additional change.
  #
  # This method can be used to perform potentially expensive operations that
  # don't need to be performed synchronously. If you need to run your callback
  # synchronously, use {::onDidChange} instead.
  #
  # * `callback` {Function} to be called when the buffer stops changing.
  #
  # Returns a {Disposable} on which `.dispose()` can be called to unsubscribe.
  onDidStopChanging: (callback) ->
    @emitter.on 'did-stop-changing', callback

  # Public: Invoke the given callback when the value of {::getEncoding} changes.
  #
  # * `callback` {Function} to be called when the encoding changes.
  #   * `encoding` {String} character set encoding of the buffer.
  #
  # Returns a {Disposable} on which `.dispose()` can be called to unsubscribe.
  onDidChangeEncoding: (callback) ->
    @emitter.on 'did-change-encoding', callback

  # Public: Invoke the given callback when the buffer is destroyed.
  #
  # * `callback` {Function} to be called when the buffer is destroyed.
  #
  # Returns a {Disposable} on which `.dispose()` can be called to unsubscribe.
  onDidDestroy: (callback) ->
    @emitter.on 'did-destroy', callback

  # Public: Get the number of milliseconds that will elapse without a change
  # before {::onDidStopChanging} observers are invoked following a change.
  #
  # Returns a {Number}.
  getStoppedChangingDelay: -> @stoppedChangingDelay

  ###
  Section: File Details
  ###

  # Public: Sets the character set encoding for this buffer.
  #
  # * `encoding` The {String} encoding to use (default: 'utf8').
  setEncoding: (encoding='utf8') ->
    return if encoding is @getEncoding()

    @encoding = encoding
    @emitter.emit 'did-change-encoding', encoding

    return

  # Public: Returns the {String} encoding of this buffer.
  getEncoding: -> @encoding

  setPreferredLineEnding: (preferredLineEnding=null) ->
    @preferredLineEnding = preferredLineEnding

  getPreferredLineEnding: ->
    @preferredLineEnding

  ###
  Section: Reading Text
  ###

  # Public: Determine whether the buffer is empty.
  #
  # Returns a {Boolean}.
  isEmpty: ->
    @getLastRow() is 0 and @lineLengthForRow(0) is 0

  # Public: Get the entire text of the buffer.
  #
  # Returns a {String}.
  getText: ->
    if @cachedText?
      @cachedText
    else
      text = ''
      for row in [0..@getLastRow()]
        text += (@lineForRow(row) + @lineEndingForRow(row))
      @cachedText = text

  # Public: Get the text in a range.
  #
  # * `range` A {Range}
  #
  # Returns a {String}
  getTextInRange: (range) ->
    range = @clipRange(Range.fromObject(range))
    startRow = range.start.row
    endRow = range.end.row

    if startRow is endRow
      @lineForRow(startRow)[range.start.column...range.end.column]
    else
      text = ''
      for row in [startRow..endRow]
        line = @lineForRow(row)
        if row is startRow
          text += line[range.start.column...]
        else if row is endRow
          text += line[0...range.end.column]
          continue
        else
          text += line
        text += @lineEndingForRow(row)
      text

  # Public: Get the text of all lines in the buffer, without their line endings.
  #
  # Returns an {Array} of {String}s.
  getLines: ->
    @lines.slice()

  # Public: Get the text of the last line of the buffer, without its line
  # ending.
  #
  # Returns a {String}.
  getLastLine: ->
    @lineForRow(@getLastRow())

  # Public: Get the text of the line at the given row, without its line ending.
  #
  # * `row` A {Number} representing a 0-indexed row.
  #
  # Returns a {String}.
  lineForRow: (row) ->
    @lines[row]

  # Public: Get the line ending for the given 0-indexed row.
  #
  # * `row` A {Number} indicating the row.
  #
  # Returns a {String}. The returned newline is represented as a literal string:
  # `'\n'`, `'\r'`, `'\r\n'`, or `''` for the last line of the buffer, which
  # doesn't end in a newline.
  lineEndingForRow: (row) ->
    @lineEndings[row]

  # Public: Get the length of the line for the given 0-indexed row, without its
  # line ending.
  #
  # * `row` A {Number} indicating the row.
  #
  # Returns a {Number}.
  lineLengthForRow: (row) ->
    @lines[row].length

  # Public: Determine if the given row contains only whitespace.
  #
  # * `row` A {Number} representing a 0-indexed row.
  #
  # Returns a {Boolean}.
  isRowBlank: (row) ->
    not /\S/.test @lineForRow(row)

  # Public: Given a row, find the first preceding row that's not blank.
  #
  # * `startRow` A {Number} identifying the row to start checking at.
  #
  # Returns a {Number} or `null` if there's no preceding non-blank row.
  previousNonBlankRow: (startRow) ->
    return null if startRow == 0

    startRow = Math.min(startRow, @getLastRow())
    for row in [(startRow - 1)..0]
      return row unless @isRowBlank(row)
    null

  # Public: Given a row, find the next row that's not blank.
  #
  # * `startRow` A {Number} identifying the row to start checking at.
  #
  # Returns a {Number} or `null` if there's no next non-blank row.
  nextNonBlankRow: (startRow) ->
    lastRow = @getLastRow()
    if startRow < lastRow
      for row in [(startRow + 1)..lastRow]
        return row unless @isRowBlank(row)
    null

  ###
  Section: Mutating Text
  ###

  # Public: Replace the entire contents of the buffer with the given text.
  #
  # * `text` A {String}
  #
  # Returns a {Range} spanning the new buffer contents.
  setText: (text) ->
    @setTextInRange(@getRange(), text, normalizeLineEndings: false)

  # Public: Replace the current buffer contents by applying a diff based on the
  # given text.
  #
  # * `text` A {String} containing the new buffer contents.
  setTextViaDiff: (text) ->
    currentText = @getText()
    return if currentText == text

    endsWithNewline = (str) ->
      /[\r\n]+$/g.test(str)

    computeBufferColumn = (str) ->
      newlineIndex = Math.max(str.lastIndexOf('\n'), str.lastIndexOf('\r'))
      if endsWithNewline(str)
        0
      else if newlineIndex == -1
        str.length
      else
        str.length - newlineIndex - 1

    @transact =>
      row = 0
      column = 0
      currentPosition = [0, 0]

      lineDiff = diff.diffLines(currentText, text)
      changeOptions = normalizeLineEndings: false

      for change in lineDiff
        # Using change.count does not account for lone carriage-returns
        lineCount = change.value.match(newlineRegex)?.length ? 0
        currentPosition[0] = row
        currentPosition[1] = column

        if change.added
          row += lineCount
          column = computeBufferColumn(change.value)
          @setTextInRange([currentPosition, currentPosition], change.value, changeOptions)

        else if change.removed
          endRow = row + lineCount
          endColumn = column + computeBufferColumn(change.value)
          @setTextInRange([currentPosition, [endRow, endColumn]], '', changeOptions)

        else
          row += lineCount
          column = computeBufferColumn(change.value)
      return

  # Public: Set the text in the given range.
  #
  # * `range` A {Range}
  # * `text` A {String}
  # * `options` (optional) {Object}
  #   * `normalizeLineEndings` (optional) {Boolean} (default: true)
  #   * `undo` (optional) {String} 'skip' will skip the undo system
  #
  # Returns the {Range} of the inserted text.
  setTextInRange: (range, newText, options) ->
    if @transactCallDepth is 0
      return @transact => @setTextInRange(range, newText, options)

    if options?
      {normalizeLineEndings, undo} = options
    normalizeLineEndings ?= true

    oldRange = @clipRange(range)
    oldText = @getTextInRange(oldRange)
    newRange = Range.fromText(oldRange.start, newText)
    change = {newStart: oldRange.start, oldExtent: oldRange.getExtent(), newExtent: newRange.getExtent(), oldText, newText, normalizeLineEndings}
    @history?.pushChange(change) if undo isnt 'skip'
    @applyChange(change)
    newRange

  # Public: Insert text at the given position.
  #
  # * `position` A {Point} representing the insertion location. The position is
  #   clipped before insertion.
  # * `text` A {String} representing the text to insert.
  # * `options` (optional) {Object}
  #   * `normalizeLineEndings` (optional) {Boolean} (default: true)
  #   * `undo` (optional) {String} 'skip' will skip the undo system
  #
  # Returns the {Range} of the inserted text.
  insert: (position, text, options) ->
    @setTextInRange(new Range(position, position), text, options)

  # Public: Append text to the end of the buffer.
  #
  # * `text` A {String} representing the text text to append.
  # * `options` (optional) {Object}
  #   * `normalizeLineEndings` (optional) {Boolean} (default: true)
  #   * `undo` (optional) {String} 'skip' will skip the undo system
  #
  # Returns the {Range} of the inserted text
  append: (text, options) ->
    @insert(@getEndPosition(), text, options)

  # Applies a change to the buffer based on its old range and new text.
  applyChange: (change) ->
    {newStart, oldExtent, newExtent, oldText, newText, normalizeLineEndings} = change
    start = Point.fromObject(newStart)
    oldRange = Range(start, start.traverse(oldExtent))
    newRange = Range(start, start.traverse(newExtent))
    oldRange.freeze()
    newRange.freeze()
    @cachedText = null

    startRow = oldRange.start.row
    endRow = oldRange.end.row
    rowCount = endRow - startRow + 1

    # Determine how to normalize the line endings of inserted text if enabled
    if normalizeLineEndings
      normalizedEnding = @preferredLineEnding ? @lineEndingForRow(startRow)
      unless normalizedEnding
        if startRow > 0
          normalizedEnding = @lineEndingForRow(startRow - 1)
        else
          normalizedEnding = null

    # Split inserted text into lines and line endings
    lines = []
    lineEndings = []
    lineStartIndex = 0
    normalizedNewText = ""
    while result = newlineRegex.exec(newText)
      line = newText[lineStartIndex...result.index]
      ending = normalizedEnding ? result[0]
      lines.push(line)
      lineEndings.push(ending)
      normalizedNewText += line + ending
      lineStartIndex = newlineRegex.lastIndex

    lastLine = newText[lineStartIndex..]
    lines.push(lastLine)
    lineEndings.push('')
    normalizedNewText += lastLine

    newText = normalizedNewText
    changeEvent = Object.freeze({oldRange, newRange, oldText, newText})
    @emitter.emit 'will-change', changeEvent

    # Update first and last line so replacement preserves existing prefix and suffix of oldRange
    prefix = @lineForRow(startRow)[0...oldRange.start.column]
    lines[0] = prefix + lines[0]
    suffix = @lineForRow(endRow)[oldRange.end.column...]
    lastIndex = lines.length - 1
    lines[lastIndex] += suffix
    lastLineEnding = @lineEndingForRow(endRow)
    lastLineEnding = normalizedEnding if lastLineEnding isnt '' and normalizedEnding?
    lineEndings[lastIndex] = lastLineEnding

    # Replace lines in oldRange with new lines
    spliceArray(@lines, startRow, rowCount, lines)
    spliceArray(@lineEndings, startRow, rowCount, lineEndings)

    # Update the offset index for position <-> character offset translation
    offsets = lines.map (line, index) ->
      {rows: 1, characters: line.length + lineEndings[index].length}
    @offsetIndex.spliceArray('rows', startRow, rowCount, offsets)

    @changeCount++
    @emitter.emit 'did-change', changeEvent

  # Public: Delete the text in the given range.
  #
  # * `range` A {Range} in which to delete. The range is clipped before deleting.
  #
  # Returns an empty {Range} starting at the start of deleted range.
  delete: (range) ->
    @setTextInRange(range, '')

  # Public: Delete the line associated with a specified row.
  #
  # * `row` A {Number} representing the 0-indexed row to delete.
  #
  # Returns the {Range} of the deleted text.
  deleteRow: (row) ->
    @deleteRows(row, row)

  # Public: Delete the lines associated with the specified row range.
  #
  # If the row range is out of bounds, it will be clipped. If the startRow is
  # greater than the end row, they will be reordered.
  #
  # * `startRow` A {Number} representing the first row to delete.
  # * `endRow` A {Number} representing the last row to delete, inclusive.
  #
  # Returns the {Range} of the deleted text.
  deleteRows: (startRow, endRow) ->
    lastRow = @getLastRow()

    [startRow, endRow] = [endRow, startRow] if startRow > endRow

    if endRow < 0
      return new Range(@getFirstPosition(), @getFirstPosition())

    if startRow > lastRow
      return new Range(@getEndPosition(), @getEndPosition())

    startRow = Math.max(0, startRow)
    endRow = Math.min(lastRow, endRow)

    if endRow < lastRow
      startPoint = new Point(startRow, 0)
      endPoint = new Point(endRow + 1, 0)
    else
      if startRow is 0
        startPoint = new Point(startRow, 0)
      else
        startPoint = new Point(startRow - 1, @lineLengthForRow(startRow - 1))
      endPoint = new Point(endRow, @lineLengthForRow(endRow))

    @delete(new Range(startPoint, endPoint))

  ###
  Section: History
  ###

  # Public: Undo the last operation. If a transaction is in progress, aborts it.
  undo: ->
    if pop = @history.popUndoStack()
      @applyChange(change) for change in pop.patch.getChanges()
      @emitDidChangeTextEvent(pop.patch)
      true
    else
      false

  # Public: Redo the last operation
  redo: ->
    if pop = @history.popRedoStack()
      @applyChange(change) for change in pop.patch.getChanges()
      @emitDidChangeTextEvent(pop.patch)
      true
    else
      false

  # Public: Batch multiple operations as a single undo/redo step.
  #
  # Any group of operations that are logically grouped from the perspective of
  # undoing and redoing should be performed in a transaction. If you want to
  # abort the transaction, call {::abortTransaction} to terminate the function's
  # execution and revert any changes performed up to the abortion.
  #
  # * `groupingInterval` (optional) The {Number} of milliseconds for which this
  #   transaction should be considered 'open for grouping' after it begins. If a
  #   transaction with a positive `groupingInterval` is committed while the previous
  #   transaction is still open for grouping, the two transactions are merged with
  #   respect to undo and redo.
  # * `fn` A {Function} to call inside the transaction.
  transact: (groupingInterval, fn) ->
    if typeof groupingInterval is 'function'
      fn = groupingInterval
      groupingInterval = 0

    checkpointBefore = @history.createCheckpoint(true)

    try
      @transactCallDepth++
      result = fn()
    catch exception
      @revertToCheckpoint(checkpointBefore, true)
      throw exception unless exception instanceof TransactionAbortedError
      return
    finally
      @transactCallDepth--

    compactedChanges = @history.groupChangesSinceCheckpoint(checkpointBefore, true)
    global.atom?.assert compactedChanges, "groupChangesSinceCheckpoint() returned false.", (error) =>
      error.metadata = {history: @history.toString()}
    @history.applyGroupingInterval(groupingInterval)
    @history.enforceUndoStackSizeLimit()
    @emitDidChangeTextEvent(compactedChanges) if compactedChanges
    result

  abortTransaction: ->
    throw new TransactionAbortedError("Transaction aborted.")

  # Public: Clear the undo stack. When calling this method within a transaction,
  # the {::onDidChangeText} event will not be triggered because the information
  # describing the changes is lost.
  clearUndoStack: -> @history.clearUndoStack()

  # Public: Create a pointer to the current state of the buffer for use
  # with {::revertToCheckpoint} and {::groupChangesSinceCheckpoint}.
  #
  # Returns a checkpoint value.
  createCheckpoint: ->
    @history.createCheckpoint(false)

  # Public: Revert the buffer to the state it was in when the given
  # checkpoint was created.
  #
  # The redo stack will be empty following this operation, so changes since the
  # checkpoint will be lost. If the given checkpoint is no longer present in the
  # undo history, no changes will be made to the buffer and this method will
  # return `false`.
  #
  # Returns a {Boolean} indicating whether the operation succeeded.
  revertToCheckpoint: (checkpoint) ->
    if truncated = @history.truncateUndoStack(checkpoint)
      @applyChange(change) for change in truncated.patch.getChanges()
      @emitDidChangeTextEvent(truncated.patch)
      true
    else
      false

  # Public: Group all changes since the given checkpoint into a single
  # transaction for purposes of undo/redo.
  #
  # If the given checkpoint is no longer present in the undo history, no
  # grouping will be performed and this method will return `false`.
  #
  # Returns a {Boolean} indicating whether the operation succeeded.
  groupChangesSinceCheckpoint: (checkpoint) ->
    @history.groupChangesSinceCheckpoint(checkpoint, false)

  # Public: Returns a list of changes since the given checkpoint.
  #
  # If the given checkpoint is no longer present in the undo history, this
  # method will return an empty {Array}.
  #
  # Returns an {Array} containing the following change {Object}s:
  # * `start` A {Point} representing where the change started.
  # * `oldExtent` A {Point} representing the replaced extent.
  # * `newExtent`: A {Point} representing the replacement extent.
  # * `newText`: A {String} representing the replacement text.
  getChangesSinceCheckpoint: (checkpoint) ->
    if patch = @history.getChangesSinceCheckpoint(checkpoint)
      normalizePatchChanges(patch.getChanges())
    else
      []

  ###
  Section: Search And Replace
  ###

  # Public: Scan regular expression matches in the entire buffer, calling the
  # given iterator function on each match.
  #
  # If you're programmatically modifying the results, you may want to try
  # {::backwardsScan} to avoid tripping over your own changes.
  #
  # * `regex` A {RegExp} to search for.
  # * `iterator` A {Function} that's called on each match with an {Object}
  #   containing the following keys:
  #   * `match` The current regular expression match.
  #   * `matchText` A {String} with the text of the match.
  #   * `range` The {Range} of the match.
  #   * `stop` Call this {Function} to terminate the scan.
  #   * `replace` Call this {Function} with a {String} to replace the match.
  scan: (regex, iterator) ->
    @scanInRange regex, @getRange(), (result) =>
      result.lineText = @lineForRow(result.range.start.row)
      result.lineTextOffset = 0
      iterator(result)

  # Public: Scan regular expression matches in the entire buffer in reverse
  # order, calling the given iterator function on each match.
  #
  # * `regex` A {RegExp} to search for.
  # * `iterator` A {Function} that's called on each match with an {Object}
  #   containing the following keys:
  #   * `match` The current regular expression match.
  #   * `matchText` A {String} with the text of the match.
  #   * `range` The {Range} of the match.
  #   * `stop` Call this {Function} to terminate the scan.
  #   * `replace` Call this {Function} with a {String} to replace the match.
  backwardsScan: (regex, iterator) ->
    @backwardsScanInRange regex, @getRange(), (result) =>
      result.lineText = @lineForRow(result.range.start.row)
      result.lineTextOffset = 0
      iterator(result)

  # Public: Scan regular expression matches in a given range , calling the given
  # iterator function on each match.
  #
  # * `regex` A {RegExp} to search for.
  # * `range` A {Range} in which to search.
  # * `iterator` A {Function} that's called on each match with an {Object}
  #   containing the following keys:
  #   * `match` The current regular expression match.
  #   * `matchText` A {String} with the text of the match.
  #   * `range` The {Range} of the match.
  #   * `stop` Call this {Function} to terminate the scan.
  #   * `replace` Call this {Function} with a {String} to replace the match.
  scanInRange: (regex, range, iterator, reverse=false) ->
    range = @clipRange(range)
    global = regex.global
    flags = "gm"
    flags += "i" if regex.ignoreCase
    regex = new RegExp(regex.source, flags)

    startIndex = @characterIndexForPosition(range.start)
    endIndex = @characterIndexForPosition(range.end)

    if reverse
      matches = new MatchIterator.Backwards(@getText(), regex, startIndex, endIndex, @backwardsScanChunkSize)
    else
      matches = new MatchIterator.Forwards(@getText(), regex, startIndex, endIndex)

    lengthDelta = 0
    until (next = matches.next()).done
      match = next.value
      callbackArgument = new SearchCallbackArgument(this, match, lengthDelta)
      iterator(callbackArgument)
      lengthDelta += callbackArgument.getReplacementDelta() unless reverse

      break unless global and callbackArgument.keepLooping()
    return

  # Public: Scan regular expression matches in a given range in reverse order,
  # calling the given iterator function on each match.
  #
  # * `regex` A {RegExp} to search for.
  # * `range` A {Range} in which to search.
  # * `iterator` A {Function} that's called on each match with an {Object}
  #   containing the following keys:
  #   * `match` The current regular expression match.
  #   * `matchText` A {String} with the text of the match.
  #   * `range` The {Range} of the match.
  #   * `stop` Call this {Function} to terminate the scan.
  #   * `replace` Call this {Function} with a {String} to replace the match.
  backwardsScanInRange: (regex, range, iterator) ->
    @scanInRange regex, range, iterator, true

  # Public: Replace all regular expression matches in the entire buffer.
  #
  # * `regex` A {RegExp} representing the matches to be replaced.
  # * `replacementText` A {String} representing the text to replace each match.
  #
  # Returns a {Number} representing the number of replacements made.
  replace: (regex, replacementText) ->
    replacements = 0

    @transact =>
      @scan regex, ({matchText, replace}) ->
        replace(matchText.replace(regex, replacementText))
        replacements++

    replacements

  ###
  Section: Buffer Range Details
  ###

  # Public: Get the range spanning from `[0, 0]` to {::getEndPosition}.
  #
  # Returns a {Range}.
  getRange: ->
    new Range(@getFirstPosition(), @getEndPosition())

  # Public: Get the number of lines in the buffer.
  #
  # Returns a {Number}.
  getLineCount: ->
    @lines.length

  # Public: Get the last 0-indexed row in the buffer.
  #
  # Returns a {Number}.
  getLastRow: ->
    @getLineCount() - 1

  # Public: Get the first position in the buffer, which is always `[0, 0]`.
  #
  # Returns a {Point}.
  getFirstPosition: ->
    new Point(0, 0)

  # Public: Get the maximal position in the buffer, where new text would be
  # appended.
  #
  # Returns a {Point}.
  getEndPosition: ->
    lastRow = @getLastRow()
    new Point(lastRow, @lineLengthForRow(lastRow))

  # Public: Get the length of the buffer in characters.
  #
  # Returns a {Number}.
  getMaxCharacterIndex: ->
    @offsetIndex.totalTo(Infinity, 'rows').characters

  # Public: Get the range for the given row
  #
  # * `row` A {Number} representing a 0-indexed row.
  # * `includeNewline` A {Boolean} indicating whether or not to include the
  #   newline, which results in a range that extends to the start
  #   of the next line.
  #
  # Returns a {Range}.
  rangeForRow: (row, includeNewline) ->
    row = Math.max(row, 0)
    row = Math.min(row, @getLastRow())

    if includeNewline and row < @getLastRow()
      new Range(new Point(row, 0), new Point(row + 1, 0))
    else
      new Range(new Point(row, 0), new Point(row, @lineLengthForRow(row)))

  # Public: Convert a position in the buffer in row/column coordinates to an
  # absolute character offset, inclusive of line ending characters.
  #
  # The position is clipped prior to translating.
  #
  # * `position` A {Point}.
  #
  # Returns a {Number}.
  characterIndexForPosition: (position) ->
    {row, column} = @clipPosition(Point.fromObject(position))

    if row < 0 or row > @getLastRow() or column < 0 or column > @lineLengthForRow(row)
      throw new Error("Position #{position} is invalid")

    {characters} = @offsetIndex.totalTo(row, 'rows')
    characters + column

  # Public: Convert an absolute character offset, inclusive of newlines, to a
  # position in the buffer in row/column coordinates.
  #
  # The offset is clipped prior to translating.
  #
  # * `offset` A {Number}.
  #
  # Returns a {Point}.
  positionForCharacterIndex: (offset) ->
    offset = Math.max(0, offset)
    offset = Math.min(@getMaxCharacterIndex(), offset)

    {rows, characters} = @offsetIndex.totalTo(offset, 'characters')
    if rows > @getLastRow()
      @getEndPosition()
    else
      new Point(rows, offset - characters)

  # Public: Clip the given range so it starts and ends at valid positions.
  #
  # For example, the position `[1, 100]` is out of bounds if the line at row 1 is
  # only 10 characters long, and it would be clipped to `(1, 10)`.
  #
  # * `range` A {Range} or range-compatible {Array} to clip.
  #
  # Returns the given {Range} if it is already in bounds, or a new clipped
  # {Range} if the given range is out-of-bounds.
  clipRange: (range) ->
    range = Range.fromObject(range)
    start = @clipPosition(range.start)
    end = @clipPosition(range.end)
    if range.start.isEqual(start) and range.end.isEqual(end)
      range
    else
      new Range(start, end)

  # Public: Clip the given point so it is at a valid position in the buffer.
  #
  # For example, the position (1, 100) is out of bounds if the line at row 1 is
  # only 10 characters long, and it would be clipped to (1, 10)
  #
  # * `position` A {Point} or point-compatible {Array}.
  #
  # Returns a new {Point} if the given position is invalid, otherwise returns
  # the given position.
  clipPosition: (position, options) ->
    position = Point.fromObject(position)
    Point.assertValid(position)
    {row, column} = position
    if row < 0
      @getFirstPosition()
    else if row > @getLastRow()
      @getEndPosition()
    else if column < 0
      Point(row, 0)
    else if column >= @lineLengthForRow(row)
      if options?.clipDirection is 'forward' and row < @getLastRow()
        Point(row + 1, 0)
      else
        Point(row, @lineLengthForRow(row))
    else
      position

  ###
  Section: Private Utility Methods
  ###

  destroy: ->
    unless @destroyed
      @cancelStoppedChangingTimeout()
      @destroyed = true
      @emitter.emit 'did-destroy'

  isAlive: -> not @destroyed

  isDestroyed: -> @destroyed

  isRetained: -> @refcount > 0

  retain: ->
    @refcount++
    this

  release: ->
    @refcount--
    @destroy() unless @isRetained()
    this

  emitDidChangeTextEvent: (patch) ->
    return if @transactCallDepth isnt 0

    @emitter.emit 'did-change-text', {changes: Object.freeze(normalizePatchChanges(patch.getChanges()))}
    @patchesSinceLastStoppedChangingEvent.push(patch)
    @scheduleDidStopChangingEvent()

  # Identifies if the buffer belongs to multiple editors.
  #
  # For example, if the {EditorView} was split.
  #
  # Returns a {Boolean}.
  hasMultipleEditors: -> @refcount > 1

  cancelStoppedChangingTimeout: ->
    clearTimeout(@stoppedChangingTimeout) if @stoppedChangingTimeout

  scheduleDidStopChangingEvent: ->
    @cancelStoppedChangingTimeout()
    stoppedChangingCallback = =>
      @stoppedChangingTimeout = null
      @emitter.emit 'did-stop-changing', {changes: Object.freeze(normalizePatchChanges(Patch.compose(@patchesSinceLastStoppedChangingEvent).getChanges()))}
      @patchesSinceLastStoppedChangingEvent = []
    @stoppedChangingTimeout = setTimeout(stoppedChangingCallback, @stoppedChangingDelay)

  logLines: (start=0, end=@getLastRow())->
    for row in [start..end]
      line = @lineForRow(row)
      console.log row, line, line.length
    return

  ###
  Section: Private History Delegate Methods
  ###

  invertChange: (change) ->
    Object.freeze({
      oldRange: change.newRange
      newRange: change.oldRange
      oldText: change.newText
      newText: change.oldText
    })

  serializeChange: (change) ->
    {
      oldRange: change.oldRange.serialize()
      newRange: change.newRange.serialize()
      oldText: change.oldText
      newText: change.newText
    }

  deserializeChange: (change) ->
    {
      oldRange: Range.deserialize(change.oldRange)
      newRange: Range.deserialize(change.newRange)
      oldText: change.oldText
      newText: change.newText
    }
