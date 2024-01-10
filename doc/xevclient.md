# xevclient.zig

This file contains two things, `DoubleBuffer` and `XevClient`.

---

The purpose of `DoubleBuffer` is to provide two buffers for data to be stored in, such
    that one buffer can be used for reading, and the other can be used for writing,
    and any reader or writer won't conflict with the other until it becomes
    necessary to swap the buffers.

To get one of the buffers, you would first obtain a lock for reading in `swap_lock`.
    Then, the active buffer (in this case, a buffer that is being read from) would be
    the one pointed to by `active_buffer`, and then that means the buffer that could
    be written to would be the one that isn't pointed to by `active_buffer`
    (`buffers[active_buffer +% 1]`).

Once a buffer is obtained, before using it, you must get a lock to its `lock`. The data
    stored in a buffer is in `data`.

`total_read` is used by user of `DoubleBuffer` to keep track the total amount of data
    read in a buffer by a reader. This doesn't necessarily need to be kept in
    `DoubleBuffer`, but it is data associated with buffers so for now it is in
    `DoubleBuffer`. 

---

`XevClient` is a stream client designed to use the `libxev` library as a backing.
    The socket of the stream is stored in `stream`. `XevClient` uses four atomic values
    to keep track of its state. `alive` will always be true, until the stream is closed.
    `writing_active` will be true whenever a write is running. `reading_active` will
    be true whenever a read is running, and will generally be running the entire
    duration of the socket until it is necessary to shut it down. `stop_queued` is true
    when a stop has been requested, but it does not necessarily mean operations such
    as writing are stopped.

`init` initializes an existing allocation of the `XevClient`, and starts listening for
    incoming data using the `libxev` loop. `submitSend` is to be called whenever any
    data is put into the `DoubleBuffer` `buffer` so that a write loop can begin if one
    is not running. A write loop will continue writing until there is no more data
    available to write. Once a write loop has ended, is must be started again with
    `submitSend`. `queueStop` is used to tell the client to stop after it has finished
    its tasks. This can be called any number of times, but only the first call will
    end up queuing a stop. `close` is an internal function that generally should not be
    called by a user. It will queue a close to actually shut down the stream, and this
    should not be called multiple times. `deinit` should only be used after the stream
    has shut down and nobody else is using the `XevClient`.

`canSend` can be used by the user to determine if it is okay to queue more data to be
    sent to the stream. `isAlive` returns the value stored in `alive`. `send` can send
    an array of bytes, but it is not required to use this and it might be desirable
    for the user to write directly to a write buffer themselves.

`XevClient` has a few required callbacks: `onRead` and `onClose`. `onRead` is how the
    user will use the `XevClient` to receive data. `onClose` will be called once after
    the stream has completely shut down.

Usage of atomics and `libxev` should be reviewed.
