export interface AnimationDriver {
  request(callback: FrameRequestCallback): number;
  cancel(id: number): void;
}

// No RAF remains queued while inactive. Frame timestamps are reset on resume,
// so file animations and orbit integration pause with the native panel.
export class RenderLoop {
  private id: number | null = null;
  private active = false;
  private lastRender: number | null = null;
  constructor(
    private readonly driver: AnimationDriver,
    private readonly fps: () => number,
    private readonly render: (dt: number) => void,
  ) {}

  setActive(active: boolean): void {
    if (active === this.active) return;
    this.active = active;
    this.lastRender = null;
    if (active) this.id = this.driver.request(this.tick);
    else if (this.id !== null) { this.driver.cancel(this.id); this.id = null; }
  }

  private tick = (timestamp: number): void => {
    this.id = null;
    if (!this.active) return;
    const interval = 1000 / this.fps();
    if (this.lastRender === null || timestamp - this.lastRender >= interval - 0.5) {
      const dt = this.lastRender === null ? 0 : Math.min((timestamp - this.lastRender) / 1000, 0.07);
      this.lastRender = timestamp;
      this.render(dt);
    }
    if (this.active) this.id = this.driver.request(this.tick);
  };
}
