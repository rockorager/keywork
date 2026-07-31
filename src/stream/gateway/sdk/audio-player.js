// AudioWorklet companion loaded internally by KeyworkSession.
class KeyworkAudioPlayer extends AudioWorkletProcessor {
  constructor() {
    super();
    this.queue = [];
    this.queuedFrames = 0;
    this.playing = false;
    this.underflows = 0;
    this.reportCountdown = 0;
    this.scheduled = null;
    this.lastCaptureTimestamp = null;
    this.lastCaptureFrame = null;
    this.targetFrames = Math.round(sampleRate * 0.06);
    this.maximumFrames = Math.round(sampleRate * 0.20);
    this.port.onmessage = (event) => {
      if (event.data?.type === "reset") {
        this.reset();
        return;
      }
      if (event.data?.type !== "samples" || !Array.isArray(event.data.channels) ||
          event.data.channels.length === 0) {
        return;
      }
      const channels = event.data.channels;
      const frames = channels[0].length;
      if (frames === 0 || channels.some((channel) => channel.length !== frames)) {
        return;
      }
      const scheduled = Number.isFinite(event.data.startFrame) &&
        Number.isFinite(event.data.captureTimestamp);
      if (this.scheduled !== null && this.scheduled !== scheduled) {
        this.reset();
        this.port.postMessage({ type: "resync", queuedFrames: 0 });
      }
      this.scheduled = scheduled;
      this.queue.push({
        channels,
        offset: 0,
        startFrame: scheduled ? event.data.startFrame : null,
        captureTimestamp: scheduled ? event.data.captureTimestamp : null,
      });
      this.queuedFrames += frames;
      if (!scheduled && this.queuedFrames > this.maximumFrames) {
        this.dropFrames(this.queuedFrames - this.targetFrames);
        this.playing = this.queuedFrames >= this.targetFrames;
        this.port.postMessage({ type: "resync", queuedFrames: this.queuedFrames });
      }
    };
  }

  reset() {
    this.queue = [];
    this.queuedFrames = 0;
    this.playing = false;
    this.scheduled = null;
    this.lastCaptureTimestamp = null;
    this.lastCaptureFrame = null;
  }

  dropFrames(count) {
    let remaining = count;
    while (remaining > 0 && this.queue.length > 0) {
      const chunk = this.queue[0];
      const available = chunk.channels[0].length - chunk.offset;
      const dropped = Math.min(remaining, available);
      chunk.offset += dropped;
      this.queuedFrames -= dropped;
      remaining -= dropped;
      if (chunk.offset === chunk.channels[0].length) {
        this.queue.shift();
      }
    }
  }

  process(_inputs, outputs) {
    const output = outputs[0];
    const frameCount = output[0]?.length || 0;
    for (const channel of output) {
      channel.fill(0);
    }
    if (this.scheduled) {
      this.processScheduled(output, frameCount);
      this.report();
      return true;
    }
    if (!this.playing) {
      this.playing = this.queuedFrames >= this.targetFrames;
      if (!this.playing) {
        this.report();
        return true;
      }
    }

    let outputOffset = 0;
    while (outputOffset < frameCount && this.queue.length > 0) {
      const chunk = this.queue[0];
      const available = chunk.channels[0].length - chunk.offset;
      const copied = Math.min(frameCount - outputOffset, available);
      for (let index = 0; index < output.length; index += 1) {
        const source = chunk.channels[Math.min(index, chunk.channels.length - 1)];
        output[index].set(source.subarray(chunk.offset, chunk.offset + copied), outputOffset);
      }
      chunk.offset += copied;
      outputOffset += copied;
      this.queuedFrames -= copied;
      if (chunk.offset === chunk.channels[0].length) {
        this.queue.shift();
      }
    }
    if (outputOffset < frameCount) {
      this.playing = false;
      this.underflows += 1;
      this.port.postMessage({ type: "underflow", underflows: this.underflows });
    }
    this.report();
    return true;
  }

  processScheduled(output, frameCount) {
    const blockStart = currentFrame;
    let outputOffset = 0;
    let wroteSamples = false;
    while (outputOffset < frameCount && this.queue.length > 0) {
      const chunk = this.queue[0];
      const available = chunk.channels[0].length - chunk.offset;
      const chunkFrame = chunk.startFrame + chunk.offset;
      if (chunkFrame < blockStart + outputOffset) {
        const dropped = Math.min(blockStart + outputOffset - chunkFrame, available);
        chunk.offset += dropped;
        this.queuedFrames -= dropped;
        if (chunk.offset === chunk.channels[0].length) {
          this.queue.shift();
        }
        continue;
      }
      const destination = chunkFrame - blockStart;
      if (destination >= frameCount) {
        break;
      }
      const copied = Math.min(frameCount - destination, available);
      for (let index = 0; index < output.length; index += 1) {
        const source = chunk.channels[Math.min(index, chunk.channels.length - 1)];
        output[index].set(source.subarray(chunk.offset, chunk.offset + copied), destination);
      }
      chunk.offset += copied;
      outputOffset = destination + copied;
      this.queuedFrames -= copied;
      this.lastCaptureTimestamp = chunk.captureTimestamp +
        chunk.offset * 1_000_000 / sampleRate;
      this.lastCaptureFrame = blockStart + outputOffset;
      wroteSamples = true;
      if (chunk.offset === chunk.channels[0].length) {
        this.queue.shift();
      }
    }
    if (wroteSamples) {
      this.playing = true;
    } else if (this.playing &&
        (this.queue.length === 0 ||
          this.queue[0].startFrame + this.queue[0].offset < blockStart + frameCount)) {
      this.playing = false;
      this.underflows += 1;
      this.port.postMessage({ type: "underflow", underflows: this.underflows });
    }
  }

  report() {
    this.reportCountdown -= 1;
    if (this.reportCountdown <= 0) {
      this.reportCountdown = 50;
      this.port.postMessage({
        type: "status",
        queuedFrames: this.queuedFrames,
        underflows: this.underflows,
        scheduled: this.scheduled === true,
        captureTimestamp: this.lastCaptureTimestamp,
        captureFrame: this.lastCaptureFrame,
      });
    }
  }
}

registerProcessor("keywork-audio-player", KeyworkAudioPlayer);
