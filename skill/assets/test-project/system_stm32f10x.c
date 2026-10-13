/**
  ******************************************************************************
  * @file    system_stm32f10x.c
  * @brief   仿真友好的最小系统初始化（测试夹具专用）
  *
  * 为什么不用官方原版：
  *   官方 system_stm32f10x.c 在 SYSCLK_FREQ_72MHz 配置下会执行
  *   SetSysClockTo72()，其中有等待外部晶振和 PLL 锁定的循环：
  *       while((RCC->CR & RCC_CR_PLLRDY) == 0) { }
  *   Keil 的 SARMCM3.DLL 软件仿真器不模拟 HSE 晶振与 PLL，
  *   RCC->CR 始终读回 0，该循环永不退出，目标会卡死在 SystemInit()，
  *   表现为 PC 停在 0x080002xx 不前进、断点永远命中不到 main。
  *
  *   因此本夹具跳过全部时钟树配置，直接给出一个固定的 SystemCoreClock。
  *   真实硬件工程应保留官方原版文件。
  ******************************************************************************
  */

#include "stm32f10x.h"

/* 仿真器下不做时钟树配置，取 HSI 默认值作为名义主频 */
uint32_t SystemCoreClock = 8000000;

/**
  * @brief  系统初始化：仿真夹具中为空实现
  * @note   刻意不访问 RCC，避免任何等待循环
  */
void SystemInit(void)
{
    SystemCoreClock = 8000000;
}

/**
  * @brief  更新 SystemCoreClock
  */
void SystemCoreClockUpdate(void)
{
    SystemCoreClock = 8000000;
}
