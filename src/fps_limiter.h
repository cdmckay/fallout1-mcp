#ifndef FALLOUT_FPS_LIMITER_H_
#define FALLOUT_FPS_LIMITER_H_

namespace fallout {

class FpsLimiter {
public:
    FpsLimiter(unsigned int fps = 60);
    void mark();
    void throttle() const;

    // MCP: For turbo mode, which runs the game faster than real time.
    void setFps(unsigned int fps);

private:
    unsigned int _fps;
    unsigned int _ticks;
};

} // namespace fallout

#endif /* FALLOUT_FPS_LIMITER_H_ */
