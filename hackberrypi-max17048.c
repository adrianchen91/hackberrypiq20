/*
 * Copyright (C) CNflysky. All rights reserved.
 * Updated by adrianchen91.
 * Fuel Gauge driver for MAX17048 chip found on HackberryPi CM5.
 *
 * Reworked to align with Acer Switch Battery Module standards.
 */

#include <linux/delay.h>
#include <linux/i2c.h>
#include <linux/math64.h>
#include <linux/module.h>
#include <linux/of.h>
#include <linux/power_supply.h>
#include <linux/property.h>
#include <linux/regmap.h>
#include <linux/version.h>

#include <linux/devm-helpers.h>
#include <linux/jiffies.h>
#include <linux/mutex.h>
#include <linux/pm.h>
#include <linux/slab.h>
#include <linux/workqueue.h>

#define MAX17048_VCELL_REG 0x02
#define MAX17048_SOC_REG 0x04
#define MAX17048_VERSION_REG 0x08
#define MAX17048_CONFIG_REG 0x0C
#define MAX17048_VALRT_REG 0x14
#define MAX17048_CRATE_REG 0x16
#define MAX17048_STATUS_REG 0x1A

/* Constants for conversions and thresholds */
#define MAX17048_VCELL_LSB_NUM 625
#define MAX17048_VCELL_LSB_DEN 8
#define MAX17048_SOC_LSB_INV 256
#define MAX17048_CRATE_LSB_NUM 52
#define MAX17048_CRATE_LSB_DEN 25000
/*
 * Direction hysteresis on the smoothed CRATE (in 1/16 LSB): enter
 * charging/discharging beyond 5 LSB (~1 %/h), leave below 3 LSB, so a load
 * sitting near the threshold does not flip the status on every refresh.
 */
#define MAX17048_CRATE_ENTER_Q4 (5 << 4)
#define MAX17048_CRATE_EXIT_Q4 (3 << 4)
/* The EMA advances at most once per this period, however often we refresh */
#define MAX17048_CRATE_EMA_PERIOD_MS 20000
#define MAX17048_FULL_SOC_THR 95
#define MAX17048_TTE_CONST_NUM 225000
#define MAX17048_TTE_CONST_DEN 13
#define MAX17048_TTE_RATE_THR 2
#define MAX17048_CAP_FULL_THR 99
#define MAX17048_CAP_CRIT_THR 5
#define MAX17048_CAP_LOW_THR 15
#define MAX17048_DEFAULT_CAP_UAH 5000000

/*
 * P3.2: CRATE is smoothed with an EMA (weight 1/4 per fresh sample, kept in
 * 1/16 LSB). Current, TTE, TTF and status all use the smoothed value, so the
 * four are mutually consistent. The old x8 TTE factor is gone: the base
 * formula is exact for 0.208 %/h per LSB. Verify against tools/discharge-log.sh
 * data (TTE within +/-20 % over a full discharge).
 */
#define MAX17048_CRATE_EMA_SHIFT 2
#define MAX17048_CRATE_FRAC_BITS 4

/*
 * FULL needs a high cell voltage as well as high SOC (there is no VBUS sense
 * on this board, so "mains online" is a heuristic derived from status), and
 * is latched with hysteresis so an idle battery at 96 % is not reported as
 * Full + online.
 */
#define MAX17048_FULL_VCELL_UV 4150000
#define MAX17048_FULL_HOLD_SOC 93
#define MAX17048_FULL_HOLD_VCELL_UV 4100000

/*
 * VERSION register: MAX17048/MAX17049 report 0x001X. The older MAX17040/41/
 * 43/44 report other values and have no CRATE register, so they are rejected.
 */
#define MAX17048_VERSION_MASK 0xFFF0
#define MAX17048_VERSION_FAMILY 0x0010

/*
 * Plausibility bounds for DT design values. These only reject typos (wrong
 * unit, missing digits); they are not battery constants and never clamp.
 */
#define MAX17048_MIN_CHARGE_UAH 100000LL	/* 100 mAh */
#define MAX17048_MAX_CHARGE_UAH 20000000LL	/* 20 Ah */
#define MAX17048_MIN_ENERGY_UWH 500000LL	/* 0.5 Wh */
#define MAX17048_MAX_ENERGY_UWH 100000000LL	/* 100 Wh */
/* Nominal LiPo cell voltage used to derive energy <-> charge: 3.7 V */
#define MAX17048_NOMINAL_DV 37
/* Implied nominal voltage outside this window means inconsistent DT values */
#define MAX17048_NOMINAL_MIN_MV 3000
#define MAX17048_NOMINAL_MAX_MV 4500

/* Poll period, snapshot lifetime and notification policy */
#define MAX17048_POLL_MS 30000
#define MAX17048_CACHE_MS 2000
#define MAX17048_HEARTBEAT_MS 300000
#define MAX17048_NOTIFY_VCELL_UV 20000

/*
 * The configuration of the regmap for MAX17048.
 * 8-bit registers, 16-bit values, Big Endian.
 */
static const struct regmap_config max17048_regmap_cfg = {
	.reg_bits = 8,
	.val_bits = 16,
	.val_format_endian = REGMAP_ENDIAN_BIG,
	.max_register = 0xFF,
	.disable_locking = false,
	.cache_type = REGCACHE_NONE,
};

/**
 * struct max17048_snapshot - One coherent set of gauge readings
 * @err:      0 if the fields below are valid, else the read error
 * @vcell_uv: Cell voltage in uV
 * @soc:      State of charge in percent (0-100)
 * @crate:    EMA-smoothed CRATE in LSB (0.208 %/h per LSB), see
 *            MAX17048_CRATE_EMA_SHIFT
 * @crate_acc: EMA accumulator, CRATE in 1/16 LSB
 */
struct max17048_snapshot {
	int err;
	int vcell_uv;
	int soc;
	int crate;
	int crate_acc;
};

/**
 * struct max17048 - Driver data for MAX17048 fuel gauge
 * @client:                 I2C client pointer
 * @regmap:                 Regmap for device access
 * @battery:                Battery power supply device
 * @ac_adapter:             AC adapter power supply device
 * @work:                   Poll work (freezable, cancelled on suspend/unbind)
 * @delay:                  Poll period in jiffies
 * @lock:                   Protects every field below it
 * @charge_full_design_uah: Design capacity in uAh
 * @energy_full_design_uwh: Design energy in uWh
 * @snap:                   Cached readings, see max17048_refresh()
 * @snap_jiffies:           When @snap was last refreshed (success or error)
 * @have_snap:              @snap_jiffies is meaningful
 * @full_latched:           FULL hysteresis state (see MAX17048_FULL_VCELL_UV)
 * @full_soc:              Highest SOC seen while @full_latched
 * @dir:                    CRATE direction state: -1, 0 or +1 (hysteresis)
 * @ema_jiffies:            Time of the last EMA step
 * @snap_valid_once:        @snap.crate_acc is seeded, EMA may run
 * @flip_cnt:               Consecutive refreshes whose raw CRATE disagreed
 *                          with the smoothed direction, see max17048_refresh()
 * @suspended:              No I2C access allowed (between suspend and resume)
 * @ntf_status:             Battery status at the last battery notification
 * @ntf_soc:                SOC at the last battery notification
 * @ntf_vcell_uv:           VCELL at the last battery notification
 * @ntf_online:             Mains online at the last mains notification
 * @ntf_jiffies:            Time of the last battery notification
 *
 * Locking: @lock is taken by the property callbacks, the poll work and the
 * PM callbacks. Order is @lock -> regmap lock -> I2C adapter lock. @lock is
 * never held across power_supply_changed() (whose uevent calls back into
 * get_property) nor across cancel_delayed_work_sync() (the work takes it).
 */
struct max17048 {
	struct i2c_client *client;
	struct regmap *regmap;
	struct power_supply *battery;
	struct delayed_work work;
	struct power_supply *ac_adapter;
	unsigned int delay;

	struct mutex lock;
	u32 charge_full_design_uah;
	u32 energy_full_design_uwh;
	struct max17048_snapshot snap;
	unsigned long snap_jiffies;
	bool have_snap;
	bool full_latched;
	int full_soc;
	int dir;
	unsigned long ema_jiffies;
	bool snap_valid_once;
	u8 flip_cnt;
	bool suspended;
	int ntf_status;
	int ntf_soc;
	int ntf_vcell_uv;
	int ntf_online;
	unsigned long ntf_jiffies;
};

/**
 * max17048_read_reg - Read a 16-bit register
 * @battery: Driver data
 * @reg:     Register address
 * @val:     Pointer to store the 16-bit register value
 *
 * One I2C transaction (register write + 2-byte read with repeated start, or
 * one SMBus word read). Returns 0 on success, negative error code on failure.
 */
static int max17048_read_reg(struct max17048 *battery, u8 reg, u32 *val)
{
	return regmap_read(battery->regmap, reg, val);
}

/**
 * max17048_refresh - Refresh the cached snapshot if it is stale
 * @battery: Driver data, @lock held
 *
 * Costs at most 3 I2C transactions (VCELL, SOC, CRATE) and none while the
 * snapshot is younger than MAX17048_CACHE_MS, so back-to-back property reads
 * share one refresh. A failed refresh is cached too, so a missing/dead gauge
 * is retried at most once per MAX17048_CACHE_MS instead of on every property
 * read. Never touches the bus while suspended; the last snapshot is served
 * instead.
 */
static void max17048_refresh(struct max17048 *battery)
{
	u32 vcell = 0, soc = 0, crate = 0;
	int ret;

	lockdep_assert_held(&battery->lock);

	if (battery->suspended)
		return;
	if (battery->have_snap &&
	    time_before(jiffies, battery->snap_jiffies +
				 msecs_to_jiffies(MAX17048_CACHE_MS)))
		return;

	ret = max17048_read_reg(battery, MAX17048_VCELL_REG, &vcell);
	if (!ret)
		ret = max17048_read_reg(battery, MAX17048_SOC_REG, &soc);
	if (!ret)
		ret = max17048_read_reg(battery, MAX17048_CRATE_REG, &crate);

	battery->have_snap = true;
	battery->snap_jiffies = jiffies;

	if (ret) {
		/*
		 * Log transitions only: a flaky bus must not spam dmesg on
		 * every poll.
		 */
		if (!battery->snap.err || battery->snap.err == -ENODATA)
			dev_warn(&battery->client->dev,
				 "gauge read failed: %d\n", ret);
		battery->snap.err = ret;
		battery->snap_valid_once = false;
		battery->flip_cnt = 0;
		return;
	}

	if (battery->snap.err && battery->snap.err != -ENODATA)
		dev_info(&battery->client->dev, "gauge reads recovered\n");
	battery->snap.err = 0;
	/* 78.125uV per LSB -> vcell * 78.125 = vcell * 625 / 8 */
	battery->snap.vcell_uv =
		vcell * MAX17048_VCELL_LSB_NUM / MAX17048_VCELL_LSB_DEN;
	soc /= MAX17048_SOC_LSB_INV;
	if (soc > 100)
		soc = 100;
	battery->snap.soc = soc;
	{
		int raw = (s16)crate * (1 << MAX17048_CRATE_FRAC_BITS);

		if (!battery->snap_valid_once) {
			battery->snap.crate_acc = raw;
			battery->snap_valid_once = true;
			battery->ema_jiffies = jiffies;
		} else {
			int acc = battery->snap.crate_acc;

			/*
			 * Fast path for a charger being plugged or unplugged:
			 * when the raw CRATE clearly says one direction and the
			 * smoothed value does not, for two refreshes in a row,
			 * jump to the raw value instead of walking there at one
			 * EMA step per period (~2 minutes).
			 */
			if ((raw >= MAX17048_CRATE_ENTER_Q4 &&
			     acc < MAX17048_CRATE_EXIT_Q4) ||
			    (raw <= -MAX17048_CRATE_ENTER_Q4 &&
			     acc > -MAX17048_CRATE_EXIT_Q4))
				battery->flip_cnt++;
			else
				battery->flip_cnt = 0;

			if (battery->flip_cnt >= 2) {
				battery->snap.crate_acc = raw;
				battery->flip_cnt = 0;
				battery->ema_jiffies = jiffies;
			} else if (time_after_eq(jiffies, battery->ema_jiffies +
					msecs_to_jiffies(MAX17048_CRATE_EMA_PERIOD_MS))) {
				battery->snap.crate_acc +=
					(raw - acc) >> MAX17048_CRATE_EMA_SHIFT;
				battery->ema_jiffies = jiffies;
			}
		}
		battery->snap.crate =
			DIV_ROUND_CLOSEST(battery->snap.crate_acc,
					  1 << MAX17048_CRATE_FRAC_BITS);
	}
}

/**
 * max17048_get_current - Get battery current in microamps
 * @battery: Driver data, @lock held, snapshot refreshed
 * @val:     Pointer to store current (uA)
 *
 * Positive = Charging, Negative = Discharging.
 */
static int max17048_get_current(struct max17048 *battery, int *val)
{
	int crate = battery->snap.crate;

	if (battery->snap.err)
		return -ENODATA;

	/*
	 * C-Rate LSB is 0.208%/hr.
	 * Current = Capacity * C-Rate
	 * Current (uA) = charge_design_uah * crate * 0.208 / 100
	 *              = charge_design_uah * crate * 52 / 25000
	 */
	*val = (int)div_s64((s64)battery->charge_full_design_uah * (s64)crate *
			    MAX17048_CRATE_LSB_NUM,
			    MAX17048_CRATE_LSB_DEN);
	return 0;
}

/**
 * max17048_get_status - Get battery charging status
 * @battery: Driver data, @lock held, snapshot refreshed
 */
static int max17048_get_status(struct max17048 *battery)
{
	int acc = battery->snap.crate_acc;
	int soc = battery->snap.soc;

	lockdep_assert_held(&battery->lock);

	if (battery->snap.err)
		return POWER_SUPPLY_STATUS_UNKNOWN;

	/* Direction with hysteresis (enter beyond 5 LSB, leave inside 3 LSB) */
	if (acc > MAX17048_CRATE_ENTER_Q4)
		battery->dir = 1;
	else if (acc < -MAX17048_CRATE_ENTER_Q4)
		battery->dir = -1;
	else if ((battery->dir > 0 && acc < MAX17048_CRATE_EXIT_Q4) ||
		 (battery->dir < 0 && acc > -MAX17048_CRATE_EXIT_Q4))
		battery->dir = 0;

	if (battery->dir > 0)
		return POWER_SUPPLY_STATUS_CHARGING;
	if (battery->dir < 0) {
		battery->full_latched = false;
		battery->full_soc = 0;
		return POWER_SUPPLY_STATUS_DISCHARGING;
	}

	/*
	 * High SOC, high voltage and low current -> Full, latched. A charger
	 * in CV mode holds SOC at its peak, so a drop of more than 1 % below
	 * the peak means the pack is on battery (1 % of jitter is tolerated so
	 * a charger in CV does not flap). CRATE reads ~0 on the flat top of the
	 * OCV curve and cannot tell by itself.
	 */
	if (soc >= MAX17048_FULL_SOC_THR &&
	    battery->snap.vcell_uv >= MAX17048_FULL_VCELL_UV) {
		battery->full_latched = true;
		battery->full_soc = max(battery->full_soc, soc);
	} else if (battery->full_latched &&
		   (soc < MAX17048_FULL_HOLD_SOC ||
		    soc < battery->full_soc - 1 ||
		    battery->snap.vcell_uv < MAX17048_FULL_HOLD_VCELL_UV)) {
		battery->full_latched = false;
		battery->full_soc = 0;
	}

	if (battery->full_latched)
		return POWER_SUPPLY_STATUS_FULL;

	return POWER_SUPPLY_STATUS_NOT_CHARGING;
}

/**
 * max17048_get_time_to_empty - Estimate time to empty
 * @battery: Driver data, @lock held, snapshot refreshed
 * @val:     Pointer to store TTE (seconds)
 */
static int max17048_get_time_to_empty(struct max17048 *battery, int *val)
{
	int crate = battery->snap.crate;
	int soc = battery->snap.soc;
	s32 discharge_rate;

	if (battery->snap.err)
		return -ENODATA;

	if (crate >= -MAX17048_TTE_RATE_THR)
		return -ENODATA;

	discharge_rate = abs(crate);
	/* TTE (s) = 225000 * soc / (discharge_rate * 13) */
	*val = (int)div_s64((s64)MAX17048_TTE_CONST_NUM * soc,
			    (s64)discharge_rate * MAX17048_TTE_CONST_DEN);
	return 0;
}

/**
 * max17048_get_time_to_full - Estimate time to full
 * @battery: Driver data, @lock held, snapshot refreshed
 * @val:     Pointer to store TTF (seconds)
 */
static int max17048_get_time_to_full(struct max17048 *battery, int *val)
{
	int crate = battery->snap.crate;
	int soc = battery->snap.soc;

	if (battery->snap.err)
		return -ENODATA;

	if (crate <= MAX17048_TTE_RATE_THR)
		return -ENODATA;

	*val = (int)div_s64((s64)MAX17048_TTE_CONST_NUM * (100 - soc),
			    (s64)crate * MAX17048_TTE_CONST_DEN);
	return 0;
}

/**
 * max17048_get_capacity_level - Get capacity level description
 * @battery: Driver data, @lock held, snapshot refreshed
 */
static int max17048_get_capacity_level(struct max17048 *battery)
{
	int soc = battery->snap.soc;
	int status = max17048_get_status(battery);

	if (battery->snap.err)
		return POWER_SUPPLY_CAPACITY_LEVEL_UNKNOWN;

	if (status == POWER_SUPPLY_STATUS_FULL || soc >= MAX17048_CAP_FULL_THR)
		return POWER_SUPPLY_CAPACITY_LEVEL_FULL;
	else if (soc <= MAX17048_CAP_CRIT_THR)
		return POWER_SUPPLY_CAPACITY_LEVEL_CRITICAL;
	else if (soc <= MAX17048_CAP_LOW_THR)
		return POWER_SUPPLY_CAPACITY_LEVEL_LOW;

	return POWER_SUPPLY_CAPACITY_LEVEL_NORMAL;
}

/**
 * battery_get_property - Power Supply API get_property callback
 * @psy: Power supply being queried
 * @psp: Property to read
 * @val: Pointer to store the property value
 *
 * Returns 0 on success, negative error code otherwise.
 */
static int battery_get_property(struct power_supply *psy,
				enum power_supply_property psp,
				union power_supply_propval *val)
{
	struct max17048 *battery = power_supply_get_drvdata(psy);
	int ret = 0;

	mutex_lock(&battery->lock);

	/* Only properties derived from gauge registers may touch the bus */
	switch (psp) {
	case POWER_SUPPLY_PROP_STATUS:
	case POWER_SUPPLY_PROP_VOLTAGE_NOW:
	case POWER_SUPPLY_PROP_CAPACITY:
	case POWER_SUPPLY_PROP_CAPACITY_LEVEL:
	case POWER_SUPPLY_PROP_CHARGE_NOW:
	case POWER_SUPPLY_PROP_ENERGY_NOW:
	case POWER_SUPPLY_PROP_CURRENT_NOW:
	case POWER_SUPPLY_PROP_TIME_TO_EMPTY_NOW:
	case POWER_SUPPLY_PROP_TIME_TO_FULL_NOW:
		max17048_refresh(battery);
		break;
	default:
		break;
	}

	switch (psp) {
	case POWER_SUPPLY_PROP_STATUS:
		val->intval = max17048_get_status(battery);
		break;
	case POWER_SUPPLY_PROP_VOLTAGE_NOW:
		ret = battery->snap.err ? -ENODATA : 0;
		if (!ret)
			val->intval = battery->snap.vcell_uv;
		break;
	case POWER_SUPPLY_PROP_CAPACITY:
		ret = battery->snap.err ? -ENODATA : 0;
		if (!ret)
			val->intval = battery->snap.soc;
		break;
	case POWER_SUPPLY_PROP_CAPACITY_LEVEL:
		val->intval = max17048_get_capacity_level(battery);
		break;
	case POWER_SUPPLY_PROP_CHARGE_NOW:
		ret = battery->snap.err ? -ENODATA : 0;
		if (!ret)
			val->intval = (int)div_s64((s64)battery->snap.soc *
						   battery->charge_full_design_uah,
						   100);
		break;
	case POWER_SUPPLY_PROP_CHARGE_FULL_DESIGN:
		val->intval = (int)battery->charge_full_design_uah;
		break;
	case POWER_SUPPLY_PROP_ENERGY_NOW:
		ret = battery->snap.err ? -ENODATA : 0;
		/* Estimate Energy Now based on SOC and Energy Full */
		if (!ret)
			val->intval = (int)div_s64((s64)battery->snap.soc *
						   battery->energy_full_design_uwh,
						   100);
		break;
	case POWER_SUPPLY_PROP_ENERGY_FULL:
	case POWER_SUPPLY_PROP_ENERGY_FULL_DESIGN:
		val->intval = (int)battery->energy_full_design_uwh;
		break;
	case POWER_SUPPLY_PROP_TECHNOLOGY:
		val->intval = POWER_SUPPLY_TECHNOLOGY_LIPO;
		break;
	case POWER_SUPPLY_PROP_CURRENT_NOW:
		ret = max17048_get_current(battery, &val->intval);
		break;
	case POWER_SUPPLY_PROP_TIME_TO_EMPTY_NOW:
		ret = max17048_get_time_to_empty(battery, &val->intval);
		break;
	case POWER_SUPPLY_PROP_TIME_TO_FULL_NOW:
		ret = max17048_get_time_to_full(battery, &val->intval);
		break;
	case POWER_SUPPLY_PROP_MODEL_NAME:
		val->strval = "MAX17048";
		break;
	case POWER_SUPPLY_PROP_MANUFACTURER:
		val->strval = "Maxim Integrated";
		break;
	case POWER_SUPPLY_PROP_PRESENT:
		val->intval = 1;
		break;
	default:
		ret = -EINVAL;
		break;
	}

	mutex_unlock(&battery->lock);
	return ret;
}

static const enum power_supply_property max17048_battery_props[] = {
	POWER_SUPPLY_PROP_STATUS,
	POWER_SUPPLY_PROP_VOLTAGE_NOW,
	POWER_SUPPLY_PROP_CAPACITY,
	POWER_SUPPLY_PROP_CAPACITY_LEVEL,
	POWER_SUPPLY_PROP_CHARGE_FULL_DESIGN,
	POWER_SUPPLY_PROP_CHARGE_NOW,
	POWER_SUPPLY_PROP_ENERGY_NOW,
	POWER_SUPPLY_PROP_ENERGY_FULL,
	POWER_SUPPLY_PROP_ENERGY_FULL_DESIGN,
	POWER_SUPPLY_PROP_TECHNOLOGY,
	POWER_SUPPLY_PROP_CURRENT_NOW,
	POWER_SUPPLY_PROP_TIME_TO_EMPTY_NOW,
	POWER_SUPPLY_PROP_TIME_TO_FULL_NOW,
	POWER_SUPPLY_PROP_MODEL_NAME,
	POWER_SUPPLY_PROP_MANUFACTURER,
	POWER_SUPPLY_PROP_PRESENT,
};

static const struct power_supply_desc max17048_battery_desc = {
	.name = "battery",
	.type = POWER_SUPPLY_TYPE_BATTERY,
	.get_property = battery_get_property,
	.properties = max17048_battery_props,
	.num_properties = ARRAY_SIZE(max17048_battery_props),
};

static int max17048_ac_get_property(struct power_supply *psy,
				    enum power_supply_property psp,
				    union power_supply_propval *val)
{
	struct max17048 *drv = power_supply_get_drvdata(psy);
	int status;

	switch (psp) {
	case POWER_SUPPLY_PROP_ONLINE:
		mutex_lock(&drv->lock);
		max17048_refresh(drv);
		status = max17048_get_status(drv);
		mutex_unlock(&drv->lock);
		val->intval = (status == POWER_SUPPLY_STATUS_CHARGING ||
			       status == POWER_SUPPLY_STATUS_FULL);
		break;
	default:
		return -EINVAL;
	}
	return 0;
}

static const enum power_supply_property max17048_ac_props[] = {
	POWER_SUPPLY_PROP_ONLINE,
};

static const struct power_supply_desc max17048_ac_desc = {
	.name = "max17048-mains",
	.type = POWER_SUPPLY_TYPE_MAINS,
	.get_property = max17048_ac_get_property,
	.properties = max17048_ac_props,
	.num_properties = ARRAY_SIZE(max17048_ac_props),
};

/*
 * Poll work. Runs on system_freezable_power_efficient_wq, so it is frozen
 * before devices suspend; suspend additionally cancels it and sets
 * @suspended, so no I2C access can happen across suspend/resume.
 *
 * Each run costs at most 3 I2C transactions (one snapshot refresh) and only
 * notifies a supply whose user-visible state changed, plus a slow heartbeat
 * for the battery so time-to-empty/current_now consumers stay fresh.
 */
static void max17048_work(struct work_struct *work)
{
	struct max17048 *drv = container_of(work, struct max17048, work.work);
	bool bat_changed = false, ac_changed = false;
	int status, online;

	mutex_lock(&drv->lock);
	if (drv->suspended) {
		mutex_unlock(&drv->lock);
		return;
	}

	max17048_refresh(drv);
	if (drv->snap.err) {
		/*
		 * Keep the last published state; a transient error is not an
		 * event.
		 */
		mutex_unlock(&drv->lock);
		queue_delayed_work(system_freezable_power_efficient_wq,
				   &drv->work, drv->delay);
		return;
	}
	status = max17048_get_status(drv);
	online = (status == POWER_SUPPLY_STATUS_CHARGING ||
		  status == POWER_SUPPLY_STATUS_FULL);

	/* status + SOC also cover capacity_level, which derives from them */
	if (status != drv->ntf_status ||
	    (!drv->snap.err &&
	     (drv->snap.soc != drv->ntf_soc ||
	      abs(drv->snap.vcell_uv - drv->ntf_vcell_uv) >=
	      MAX17048_NOTIFY_VCELL_UV)) ||
	    time_after_eq(jiffies,
			  drv->ntf_jiffies +
			  msecs_to_jiffies(MAX17048_HEARTBEAT_MS))) {
		bat_changed = true;
		drv->ntf_status = status;
		if (!drv->snap.err) {
			drv->ntf_soc = drv->snap.soc;
			drv->ntf_vcell_uv = drv->snap.vcell_uv;
		}
		drv->ntf_jiffies = jiffies;
	}
	if (online != drv->ntf_online) {
		ac_changed = true;
		drv->ntf_online = online;
	}
	mutex_unlock(&drv->lock);

	/* Outside @lock: the resulting uevent calls get_property */
	if (bat_changed)
		power_supply_changed(drv->battery);
	if (ac_changed)
		power_supply_changed(drv->ac_adapter);

	/*
	 * Requeueing races neither suspend nor unbind: both use
	 * cancel_delayed_work_sync(), which also kills a self-requeued
	 * instance.
	 */
	queue_delayed_work(system_freezable_power_efficient_wq, &drv->work,
			   drv->delay);
}

/*
 * No interrupt support, deliberately. On HackberryPi CM5 the ALRT# pin only
 * has a pull-up and is not wired to any GPIO, so an IRQ can never fire. The
 * previous handler also never cleared CONFIG.ALRT / STATUS, which with a
 * level-low trigger would have been an interrupt storm. If a board ever wires
 * ALRT#, a correct handler must clear STATUS alert bits and then CONFIG.ALRT.
 * Polling (30 s, plus on-demand refresh) is ample for a 5 Ah pack.
 */

/**
 * max17048_check_range - Validate a design value from firmware
 * @dev:  Device for logging
 * @what: Name of the source property, for the warning
 * @val:  Value; <= 0 means "not provided" (battery_info uses -EINVAL)
 * @min:  Lowest plausible value
 * @max:  Highest plausible value
 *
 * Returns @val if plausible, 0 (= absent) otherwise. Never clamps.
 */
static u32 max17048_check_range(struct device *dev, const char *what, s64 val,
				s64 min, s64 max)
{
	if (val <= 0)
		return 0;
	if (val < min || val > max) {
		dev_warn(dev,
			 "ignoring implausible %s = %lld (allowed %lld..%lld)\n",
			 what, val, min, max);
		return 0;
	}
	return (u32)val;
}

/**
 * max17048_read_legacy_design - Read the legacy device-node design values
 * @dev:    Device
 * @charge: Out: design charge in uAh, 0 if absent or implausible
 * @energy: Out: design energy in uWh, 0 if absent or implausible
 */
static void max17048_read_legacy_design(struct device *dev, u32 *charge,
					u32 *energy)
{
	u32 v;

	*charge = 0;
	*energy = 0;

	if (!device_property_read_u32(dev, "charge-full-design-microamp-hours",
				      &v))
		*charge = max17048_check_range(dev,
					       "charge-full-design-microamp-hours",
					       v, MAX17048_MIN_CHARGE_UAH,
					       MAX17048_MAX_CHARGE_UAH);
	else if (!device_property_read_u32(dev, "battery-capacity", &v))
		/* Fallback to legacy battery-capacity (mAh) */
		*charge = max17048_check_range(dev, "battery-capacity (uAh)",
					       (s64)v * 1000,
					       MAX17048_MIN_CHARGE_UAH,
					       MAX17048_MAX_CHARGE_UAH);

	if (!device_property_read_u32(dev, "energy-full-design-microwatt-hours",
				      &v))
		*energy = max17048_check_range(dev,
					       "energy-full-design-microwatt-hours",
					       v, MAX17048_MIN_ENERGY_UWH,
					       MAX17048_MAX_ENERGY_UWH);
}

/**
 * max17048_set_design - Fill in the design values, deriving missing ones
 * @drv:     Driver data (@lock held once the supplies are registered)
 * @charge:  Validated design charge in uAh, 0 if unknown
 * @energy:  Validated design energy in uWh, 0 if unknown
 * @verbose: Log defaults, inconsistencies and the result
 *
 * A missing value is derived from the other one at the 3.7 V nominal cell
 * voltage; if both are missing, 5000 mAh (and thus 18.5 Wh) is used.
 * Returns true if either stored value changed.
 */
static bool max17048_set_design(struct max17048 *drv, u32 charge, u32 energy,
				bool verbose)
{
	struct device *dev = &drv->client->dev;
	bool changed;
	u32 mv;

	if (!charge && energy)
		charge = (u32)div_u64((u64)energy * 10, MAX17048_NOMINAL_DV);
	if (!charge) {
		if (verbose)
			dev_warn(dev,
				 "Capacity not configured, default 5000mAh\n");
		charge = MAX17048_DEFAULT_CAP_UAH;
	}
	if (!energy)
		energy = (u32)div_u64((u64)charge * MAX17048_NOMINAL_DV, 10);

	/* uWh / uAh = V; warn (but keep both) if they cannot be the same pack */
	mv = (u32)div_u64((u64)energy * 1000, charge);
	if (verbose &&
	    (mv < MAX17048_NOMINAL_MIN_MV || mv > MAX17048_NOMINAL_MAX_MV))
		dev_warn(dev,
			 "design %u uAh / %u uWh imply %u mV nominal; check DT\n",
			 charge, energy, mv);

	changed = charge != drv->charge_full_design_uah ||
		  energy != drv->energy_full_design_uwh;
	drv->charge_full_design_uah = charge;
	drv->energy_full_design_uwh = energy;

	if (verbose)
		dev_info(dev, "MAX17048: Design: %u uAh, %u uWh\n",
			 charge, energy);
	return changed;
}

/*
 * Suspend: stop polling and forbid bus access. @suspended is set first so a
 * concurrently running work instance cannot start another refresh; the
 * cancel (outside @lock, the work takes it) then waits for it and removes any
 * self-requeued instance. Property reads while suspended get the cached data.
 */
static int max17048_suspend(struct device *dev)
{
	struct max17048 *drv = dev_get_drvdata(dev);

	mutex_lock(&drv->lock);
	drv->suspended = true;
	mutex_unlock(&drv->lock);

	cancel_delayed_work_sync(&drv->work);
	return 0;
}

/*
 * Resume: allow bus access again, mark the snapshot stale and run the poll
 * work now. The refresh happens in the (freezable) work, i.e. after tasks
 * are thawed and the I2C adapter is fully resumed, not in this callback.
 */
static int max17048_resume(struct device *dev)
{
	struct max17048 *drv = dev_get_drvdata(dev);

	mutex_lock(&drv->lock);
	drv->suspended = false;
	drv->have_snap = false;
	drv->snap_valid_once = false; /* stale EMA: restart smoothing */
	drv->flip_cnt = 0;
	drv->full_latched = false;
	drv->full_soc = 0;
	drv->dir = 0;
	mutex_unlock(&drv->lock);

	mod_delayed_work(system_freezable_power_efficient_wq, &drv->work, 0);
	return 0;
}

static DEFINE_SIMPLE_DEV_PM_OPS(max17048_pm_ops, max17048_suspend,
				max17048_resume);

static int max17048_probe(struct i2c_client *client)
{
	struct device *dev = &client->dev;
	struct max17048 *drv;
	struct power_supply_config psycfg = {};
	struct power_supply_battery_info *info;
	u32 leg_charge, leg_energy, bi_charge = 0, bi_energy = 0;
	u32 version;
	bool changed;
	int ret;

	/*
	 * regmap-i2c needs plain I2C, or SMBus word access (big-endian
	 * swapped).
	 */
	if (!i2c_check_functionality(client->adapter, I2C_FUNC_I2C) &&
	    !i2c_check_functionality(client->adapter,
				     I2C_FUNC_SMBUS_WORD_DATA))
		return -ENODEV;

	drv = devm_kzalloc(dev, sizeof(*drv), GFP_KERNEL);
	if (!drv)
		return -ENOMEM;

	drv->client = client;
	drv->regmap = devm_regmap_init_i2c(client, &max17048_regmap_cfg);
	if (IS_ERR(drv->regmap))
		return PTR_ERR(drv->regmap);

	ret = devm_mutex_init(dev, &drv->lock);
	if (ret)
		return ret;
	drv->snap.err = -ENODATA;
	/* Impossible values: the first poll notifies both supplies */
	drv->ntf_status = -1;
	drv->ntf_soc = -1;
	drv->ntf_online = -1;
	drv->ntf_jiffies = jiffies;
	drv->delay = msecs_to_jiffies(MAX17048_POLL_MS);

	/*
	 * Presence/ID check before anything is registered: a missing gauge must
	 * not create a "battery" supply that only ever returns errors.
	 */
	ret = max17048_read_reg(drv, MAX17048_VERSION_REG, &version);
	if (ret) {
		/* One retry: the bus is shared with the touchscreen */
		usleep_range(1000, 2000);
		ret = max17048_read_reg(drv, MAX17048_VERSION_REG, &version);
	}
	if (ret) {
		dev_err(dev, "no fuel gauge at 0x%02x (VERSION read: %d)\n",
			client->addr, ret);
		return -ENODEV;
	}
	if ((version & MAX17048_VERSION_MASK) != MAX17048_VERSION_FAMILY) {
		dev_err(dev, "unexpected VERSION 0x%04x, not a MAX17048/49\n",
			version);
		return -ENODEV;
	}
	dev_dbg(dev, "VERSION 0x%04x\n", version);

	/* Provisional design values, so registration-time uevents are sane */
	max17048_read_legacy_design(dev, &leg_charge, &leg_energy);
	max17048_set_design(drv, leg_charge, leg_energy, false);

	i2c_set_clientdata(client, drv);

	/* Register Battery */
	psycfg.drv_data = drv;
/*
 * The version guard below is kept unchanged on purpose. The 6.12 headers
 * define both of_node and fwnode in struct power_supply_config, so the field
 * set alone does not say which one 6.12 expects, and the 6.18 threshold could
 * not be checked against headers here. On 6.12 this still sets of_node only.
 */
#if LINUX_VERSION_CODE >= KERNEL_VERSION(6, 18, 0)
	psycfg.fwnode = dev_fwnode(dev);
#else
	psycfg.of_node = dev->of_node;
#endif

	drv->battery =
		devm_power_supply_register(dev, &max17048_battery_desc, &psycfg);
	if (IS_ERR(drv->battery)) {
		dev_err(dev, "Failed to register battery\n");
		return PTR_ERR(drv->battery);
	}

	/* Register AC Adapter */
	drv->ac_adapter =
		devm_power_supply_register(dev, &max17048_ac_desc, &psycfg);
	if (IS_ERR(drv->ac_adapter)) {
		dev_err(dev, "Failed to register AC adapter\n");
		return PTR_ERR(drv->ac_adapter);
	}

	/*
	 * Standard binding: monitored-battery -> simple-battery node. It needs a
	 * registered psy, hence after registration. Per value, it takes precedence
	 * over the legacy device-node properties, which remain the fallback.
	 */
	ret = power_supply_get_battery_info(drv->battery, &info);
	if (!ret) {
		bi_charge = max17048_check_range(
			dev, "monitored-battery charge-full-design-microamp-hours",
			info->charge_full_design_uah, MAX17048_MIN_CHARGE_UAH,
			MAX17048_MAX_CHARGE_UAH);
		bi_energy = max17048_check_range(
			dev, "monitored-battery energy-full-design-microwatt-hours",
			info->energy_full_design_uwh, MAX17048_MIN_ENERGY_UWH,
			MAX17048_MAX_ENERGY_UWH);
		power_supply_put_battery_info(drv->battery, info);
	} else if (ret != -ENODEV && ret != -ENOENT) {
		dev_warn(dev, "monitored-battery unusable (%d), using legacy properties\n",
			 ret);
	}

	mutex_lock(&drv->lock);
	changed = max17048_set_design(drv, bi_charge ? bi_charge : leg_charge,
				      bi_energy ? bi_energy : leg_energy, true);
	mutex_unlock(&drv->lock);
	if (changed)
		power_supply_changed(drv->battery);

	if (client->irq)
		dev_info(dev, "IRQ %d ignored: driver polls (no ALRT# wiring)\n",
			 client->irq);

	/*
	 * Added after the supplies, so devres cancels the work (synchronously,
	 * including a self-requeued instance) before the supplies and the regmap
	 * are torn down on unbind. Nothing else queues the work afterwards.
	 */
	ret = devm_delayed_work_autocancel(dev, &drv->work, max17048_work);
	if (ret)
		return ret;

	queue_delayed_work(system_freezable_power_efficient_wq, &drv->work,
			   drv->delay);

	return 0;
}

static const struct of_device_id max17048_of_ids[] = {
	{ .compatible = "hackberrypi,max17048-battery" },
	{ }
};
MODULE_DEVICE_TABLE(of, max17048_of_ids);

static const struct i2c_device_id max17048_id[] = {
	{ "max17048-battery", 0 },
	{ }
};
MODULE_DEVICE_TABLE(i2c, max17048_id);

static struct i2c_driver max17048_driver = {
	.driver = {
		.name = "max17048",
		.of_match_table = max17048_of_ids,
		.pm = pm_sleep_ptr(&max17048_pm_ops),
	},
	.probe = max17048_probe,
	.id_table = max17048_id,
};

module_i2c_driver(max17048_driver);

MODULE_DESCRIPTION("MAX17048 fuel gauge driver for HackBerryPi CM5");
MODULE_AUTHOR("CNflysky <cnflysky@qq.com>");
MODULE_LICENSE("GPL");
