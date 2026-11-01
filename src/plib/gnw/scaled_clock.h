#ifndef FALLOUT_PLIB_GNW_SCALED_CLOCK_H_
#define FALLOUT_PLIB_GNW_SCALED_CLOCK_H_

namespace fallout {

// MCP: The engine's clock, which can run faster than real time for
// development (turbo mode). With a factor of 1 it is real time, exactly.
// Changing the factor carries on from the current time, so nothing sees time
// jump. The arithmetic is unsigned and wraps, as SDL_GetTicks does.
class ScaledClock {
public:
    // The clock's time when real time is `now`.
    unsigned int at(unsigned int now) const
    {
        return _origin + (now - _base) * _factor;
    }

    // Changes the speed at real time `now`.
    void setFactor(unsigned int factor, unsigned int now)
    {
        _origin = at(now);
        _base = now;
        _factor = factor;
    }

    unsigned int factor() const
    {
        return _factor;
    }

private:
    unsigned int _base = 0;
    unsigned int _origin = 0;
    unsigned int _factor = 1;
};

} // namespace fallout

#endif /* FALLOUT_PLIB_GNW_SCALED_CLOCK_H_ */
